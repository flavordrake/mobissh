/**
 * TDD red baseline for modal cancel button unresponsive on connection failure (#388)
 *
 * Bug: When a connection attempt fails (e.g. Tailscale down), the connection status
 * overlay appears. The cancel button does nothing — app hangs.
 *
 * Root causes to verify:
 * 1. Cancel button handler calls disconnect(), but disconnect() doesn't abort the
 *    active connection cycle's AbortController
 * 2. _connectTimeout is a local variable inside _openWebSocket — disconnect() can't
 *    clear it, so the overlay may reappear after cancel
 * 3. disconnect() doesn't transition session to 'failed' when in 'connecting' state
 *    reliably when the cycle's close handler races with the cancel
 * 4. The error dialog path (showErrorDialog) dismisses but doesn't abort the cycle
 *
 * All tests should FAIL on current main and PASS when #388 is implemented.
 */
import { describe, it, expect, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const connectionSrc = readFileSync(resolve(__dirname, '../connection.ts'), 'utf-8');
const uiSrc = readFileSync(resolve(__dirname, '../ui.ts'), 'utf-8');

/** Extract a function body from source by matching braces. */
function extractFnBody(src: string, fnName: string): string {
  const fnStart = src.indexOf(fnName);
  if (fnStart === -1) return '';
  const sigEnd = src.indexOf('{', src.indexOf(')', fnStart));
  if (sigEnd === -1) return '';
  let depth = 0;
  let fnEnd = sigEnd;
  for (let i = sigEnd; i < src.length; i++) {
    if (src[i] === '{') depth++;
    if (src[i] === '}') depth--;
    if (depth === 0) { fnEnd = i + 1; break; }
  }
  return src.slice(fnStart, fnEnd);
}

describe('Modal cancel button responsiveness (#388)', () => {

  // ── 1. Cancel button has a click handler (structural) ──────────────────

  describe('cancel button wiring in _showConnectionStatus', () => {
    it('cancel button has an event listener that calls disconnect', () => {
      const fnBody = extractFnBody(connectionSrc, 'function _showConnectionStatus');
      expect(fnBody.length).toBeGreaterThan(50);

      // The cancel button should have a click handler
      expect(fnBody).toContain('addEventListener');
      expect(fnBody).toContain('click');
      // The handler should call disconnect
      expect(fnBody).toContain('disconnect');
    });
  });

  // ── 2. Cancel handler aborts the connection cycle ──────────────────────

  describe('cancel handler aborts connection cycle', () => {
    it('disconnect() aborts session._cycle.controller', () => {
      const fnBody = extractFnBody(connectionSrc, 'function disconnect');
      expect(fnBody.length).toBeGreaterThan(50);

      // disconnect must abort the active cycle's AbortController so all WS
      // listeners registered with that signal are auto-removed. Without this,
      // the close handler fires after cancel and triggers reconnect.
      const abortsController = fnBody.includes('_cycle') && fnBody.includes('abort');
      const abortsCycle = fnBody.includes('.abort()');
      expect(abortsController || abortsCycle).toBe(true);
    });

    it('disconnect() aborts cycle BEFORE closing the WebSocket', () => {
      const fnBody = extractFnBody(connectionSrc, 'function disconnect');
      expect(fnBody.length).toBeGreaterThan(50);

      // The abort must come before ws.close() to prevent the close handler
      // from firing and triggering a reconnect loop
      const abortIdx = fnBody.indexOf('.abort()');
      const wsCloseIdx = fnBody.indexOf('ws.close()');
      expect(abortIdx).toBeGreaterThan(-1);
      expect(wsCloseIdx).toBeGreaterThan(-1);
      expect(abortIdx).toBeLessThan(wsCloseIdx);
    });
  });

  // ── 3. Cancel handler closes the WebSocket ─────────────────────────────

  describe('cancel handler closes WebSocket', () => {
    it('disconnect() closes session.ws', () => {
      const fnBody = extractFnBody(connectionSrc, 'function disconnect');
      expect(fnBody.length).toBeGreaterThan(50);
      expect(fnBody).toContain('ws.close()');
    });
  });

  // ── 4. Cancel handler dismisses the overlay ────────────────────────────

  describe('cancel handler dismisses overlay', () => {
    it('disconnect() calls _dismissConnectionStatus', () => {
      const fnBody = extractFnBody(connectionSrc, 'function disconnect');
      expect(fnBody.length).toBeGreaterThan(50);
      expect(fnBody).toContain('_dismissConnectionStatus');
    });

    it('cancel button click handler calls _dismissConnectionStatus', () => {
      const fnBody = extractFnBody(connectionSrc, 'function _showConnectionStatus');
      expect(fnBody.length).toBeGreaterThan(50);
      // The click handler should dismiss the overlay
      expect(fnBody).toContain('_dismissConnectionStatus');
    });
  });

  // ── 5. Cancel handler clears pending _connectTimeout ───────────────────

  describe('cancel handler clears pending timeouts', () => {
    it('_connectTimeout is accessible to disconnect() (not trapped in _openWebSocket closure)', () => {
      // Currently _connectTimeout is declared as `let` inside _openWebSocket,
      // making it inaccessible to disconnect(). It needs to be module-level
      // or stored on the session so disconnect() can clear it.
      const fnBody = extractFnBody(connectionSrc, 'function disconnect');
      expect(fnBody.length).toBeGreaterThan(50);

      // disconnect must clear _connectTimeout to prevent the overlay from
      // reappearing after the user clicks cancel
      const clearsTimeout = fnBody.includes('_connectTimeout') || fnBody.includes('connectTimeout');
      expect(clearsTimeout).toBe(true);
    });

    it('_connectTimeout is declared at module level (not inside _openWebSocket)', () => {
      // Find the _connectTimeout declaration
      const declMatch = connectionSrc.match(/let _connectTimeout/);
      expect(declMatch).not.toBeNull();

      // It should NOT be inside _openWebSocket's body — it should be module-level
      const openWsBody = extractFnBody(connectionSrc, 'function _openWebSocket');
      expect(openWsBody).not.toContain('let _connectTimeout');
    });
  });

  // ── 6. Cancel handler transitions session state ────────────────────────

  describe('cancel handler transitions session state', () => {
    it('disconnect() transitions connecting session to failed', () => {
      const fnBody = extractFnBody(connectionSrc, 'function disconnect');
      expect(fnBody.length).toBeGreaterThan(50);

      // When the user cancels during connection, the session must transition
      // to 'failed' so the UI doesn't show "connecting" forever.
      // disconnect() must call transitionSession for connecting state.
      expect(fnBody).toContain('transitionSession');
    });

    it('disconnect() does NOT set profile to null before transitioning state', () => {
      const fnBody = extractFnBody(connectionSrc, 'function disconnect');
      expect(fnBody.length).toBeGreaterThan(50);

      // Current bug: disconnect() sets session.profile = null early, which
      // can interfere with state transition side-effects that check profile.
      // The profile nulling should happen AFTER the state transition, or not at all.
      const profileNullIdx = fnBody.indexOf('profile = null');
      const transitionIdx = fnBody.indexOf('transitionSession');
      if (profileNullIdx > -1 && transitionIdx > -1) {
        expect(profileNullIdx).toBeGreaterThan(transitionIdx);
      }
    });
  });

  // ── 7. Overlay dismissable via error dialog path ───────────────────────

  describe('error dialog cancel also aborts connection', () => {
    it('showErrorDialog dismiss handler exists in ui.ts', () => {
      const fnBody = extractFnBody(uiSrc, 'function showErrorDialog');
      expect(fnBody.length).toBeGreaterThan(50);
      // The dismiss button should have a click handler
      expect(fnBody).toContain('addEventListener');
      expect(fnBody).toContain('click');
    });

    it('WS error handler in _openWebSocket calls disconnect or aborts cycle on non-silent errors', () => {
      const fnBody = extractFnBody(connectionSrc, 'function _openWebSocket');
      expect(fnBody.length).toBeGreaterThan(50);

      // The 'error' event handler currently calls showErrorDialog but doesn't
      // abort the cycle or cancel reconnect. The user sees an error but the
      // app keeps trying to reconnect in the background.
      // After the fix, the error handler should call disconnect() when showing
      // the error dialog (non-silent mode), not just showErrorDialog alone.

      // Find the WS error addEventListener — it's the last addEventListener
      // in _openWebSocket, after the 'close' handler
      const errorListenerIdx = fnBody.lastIndexOf("'error'");
      expect(errorListenerIdx).toBeGreaterThan(-1);

      // Extract just the error handler callback body (from 'error' to the
      // closing of the addEventListener call — look for the }, signal pattern)
      const afterError = fnBody.slice(errorListenerIdx);
      const handlerEnd = afterError.indexOf('}, signal');
      expect(handlerEnd).toBeGreaterThan(-1);
      const errorHandler = afterError.slice(0, handlerEnd);

      // The error handler should call disconnect() or abort the cycle,
      // not just show a dialog and leave the cycle running
      const callsDisconnect = errorHandler.includes('disconnect(');
      const abortsCycle = errorHandler.includes('.abort()');
      const cancelsReconnect = errorHandler.includes('cancelReconnect');
      expect(callsDisconnect || abortsCycle || cancelsReconnect).toBe(true);
    });
  });
});
