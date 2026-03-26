/**
 * TDD red baseline for session UI state integration (#324)
 *
 * Part C of the state machine migration wires the session lifecycle
 * state into the UI layer:
 *   - switchSession checks session.state and shows disconnect overlay
 *   - Session menu entries reflect state visually (CSS class per state)
 *   - Input routing guards on state with user-visible feedback
 *   - onStateChange subscriber updates UI on transitions
 *   - No duplicate listeners after reconnect
 *
 * These tests will FAIL until the develop agent completes the integration.
 */
import { describe, it, expect, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

// Stub browser globals before importing modules
vi.stubGlobal('localStorage', {
  getItem: () => null,
  setItem: () => {},
  removeItem: () => {},
  clear: () => {},
  length: 0,
  key: () => null,
});
vi.stubGlobal('location', { hostname: 'localhost', hash: '' });

// Read source files for structural assertions
const uiSrc = readFileSync(resolve(__dirname, '../ui.ts'), 'utf-8');
const connectionSrc = readFileSync(resolve(__dirname, '../connection.ts'), 'utf-8');
const _terminalSrc = readFileSync(resolve(__dirname, '../terminal.ts'), 'utf-8');
const stateSrc = readFileSync(resolve(__dirname, '../state.ts'), 'utf-8');

describe('session UI state integration (#324)', () => {
  // ── 1. switchSession shows disconnect state ─────────────────────────────

  describe('switchSession checks session.state', () => {
    it('switchSession source reads session.state (not just isSessionConnected for resize)', () => {
      // switchSession should check the lifecycle state to decide whether to
      // show a disconnect overlay or indicator. Currently it only uses
      // isSessionConnected for the resize guard. We need an explicit state
      // check that gates the UI presentation.
      const switchFn = uiSrc.match(
        /export function switchSession\b[\s\S]*?^}/m,
      );
      expect(switchFn, 'switchSession function should exist').toBeTruthy();
      const body = switchFn![0];

      // The function should read session.state directly (not just via isSessionConnected)
      const readsState = body.includes('session.state') || body.includes('.state !==') || body.includes('.state ===');
      expect(readsState, 'switchSession should read session.state to check lifecycle').toBe(true);
    });

    it('switchSession shows a disconnect indicator when session is not connected', () => {
      // The function should show some UI element (overlay, class, toast) when
      // switching to a disconnected session. Look for disconnect-related DOM
      // manipulation conditional on state.
      const switchFn = uiSrc.match(
        /export function switchSession\b[\s\S]*?^}/m,
      );
      expect(switchFn).toBeTruthy();
      const body = switchFn![0];

      // Should contain some indication of disconnect state handling:
      // e.g., classList.add('disconnected'), overlay, toast, or similar
      const hasDisconnectUI =
        body.includes('disconnect') ||
        body.includes('overlay') ||
        body.includes('toast') ||
        body.includes('not connected') ||
        body.includes('conn-status');
      expect(
        hasDisconnectUI,
        'switchSession should show disconnect indicator when session is not connected',
      ).toBe(true);
    });
  });

  // ── 2. Session menu reflects session state ──────────────────────────────

  describe('session menu reflects session state', () => {
    it('renderSessionList applies state-based CSS classes to session entries', () => {
      // renderSessionList (or the session item template) should include a CSS
      // class derived from session.state, like `session-disconnected`,
      // `session-connecting`, or `session-${state}`.
      const renderFn = uiSrc.match(
        /export function renderSessionList\b[\s\S]*?^}/m,
      );
      expect(renderFn, 'renderSessionList function should exist').toBeTruthy();
      const body = renderFn![0];

      // Check for state-derived CSS class patterns
      const hasStateClass =
        body.includes('session-disconnected') ||
        body.includes('session-connecting') ||
        body.includes('session-connected') ||
        body.includes('session-idle') ||
        body.includes('session-failed') ||
        body.includes('session-${') ||
        body.includes('`session-${s.state}') ||
        body.includes('s.state');
      expect(
        hasStateClass,
        'renderSessionList should apply CSS class based on session.state',
      ).toBe(true);
    });

    it('session item HTML includes a state-derived class (not just active)', () => {
      // The session-item template currently only has `active` class.
      // After Part C, it should include a class reflecting lifecycle state.
      const itemTemplate = uiSrc.match(/class="session-item[^"]*"/g) || [];
      const hasStateInTemplate = itemTemplate.some(
        (cls) =>
          cls.includes('session-disconnected') ||
          cls.includes('session-connecting') ||
          cls.includes('session-${') ||
          cls.includes('${s.state}') ||
          cls.includes('state'),
      );
      expect(
        hasStateInTemplate,
        'session-item template should include state-derived CSS class',
      ).toBe(true);
    });

    it('the dot indicator reflects connection state (not always the same color)', () => {
      // The session-item-dot should vary by state. Look for state-conditional
      // styling or class on the dot element.
      const renderFn = uiSrc.match(
        /export function renderSessionList\b[\s\S]*?^}/m,
      );
      expect(renderFn).toBeTruthy();
      const body = renderFn![0];

      const dotReflectsState =
        body.includes('session-item-dot') &&
        (body.includes('s.state') || body.includes('isSessionConnected'));
      expect(
        dotReflectsState,
        'session-item-dot should reflect session lifecycle state',
      ).toBe(true);
    });
  });

  // ── 3. Input routing guards on state ────────────────────────────────────

  describe('input routing guards on state', () => {
    it('sendSSHInput guards on session state (structural)', () => {
      // sendSSHInput currently does a silent return when not connected.
      // After Part C, it should provide user-visible feedback (toast or similar)
      // when input is dropped.
      const sendFn = connectionSrc.match(
        /export function sendSSHInput\b[\s\S]*?^}/m,
      );
      expect(sendFn, 'sendSSHInput function should exist').toBeTruthy();
      const body = sendFn![0];

      // Must use isSessionConnected or session.state check (already present)
      const guardsOnState =
        body.includes('isSessionConnected') || body.includes('session.state');
      expect(guardsOnState, 'sendSSHInput should guard on session state').toBe(true);
    });

    it('sendSSHInput shows feedback when input is dropped on disconnected session', () => {
      // The current implementation silently returns. Part C should add a toast
      // or visual feedback so the user knows their input was dropped.
      const sendFn = connectionSrc.match(
        /export function sendSSHInput\b[\s\S]*?^}/m,
      );
      expect(sendFn).toBeTruthy();
      const body = sendFn![0];

      const hasUserFeedback =
        body.includes('toast') ||
        body.includes('Toast') ||
        body.includes('showToast') ||
        body.includes('setStatus') ||
        body.includes('showError') ||
        body.includes('feedback') ||
        body.includes('not connected') ||
        body.includes('disconnected');
      expect(
        hasUserFeedback,
        'sendSSHInput should show user feedback when input is dropped',
      ).toBe(true);
    });
  });

  // ── 4. onStateChange subscriber updates UI ──────────────────────────────

  describe('onStateChange subscriber updates UI', () => {
    it('ui.ts imports onStateChange from state module', () => {
      const importMatch = uiSrc.match(
        /import\s+\{[^}]*onStateChange[^}]*\}\s+from\s+['"]\.\/state/,
      );
      expect(
        importMatch,
        'ui.ts should import onStateChange from state module',
      ).toBeTruthy();
    });

    it('ui.ts calls onStateChange to register a subscriber', () => {
      // After import, ui.ts should actually call onStateChange(callback)
      // to wire up automatic UI updates when session state transitions.
      const callsOnStateChange = uiSrc.includes('onStateChange(');
      expect(
        callsOnStateChange,
        'ui.ts should call onStateChange() to register a UI update subscriber',
      ).toBe(true);
    });

    it('the onStateChange callback triggers renderSessionList or UI refresh', () => {
      // The callback passed to onStateChange should invoke renderSessionList
      // or update the session menu button to reflect the new state.
      // Extract the onStateChange call and its callback body.
      const callSite = uiSrc.match(
        /onStateChange\(\s*(?:\([^)]*\)|[a-zA-Z_$][a-zA-Z0-9_$]*)\s*=>\s*\{[\s\S]*?\}\s*\)/,
      );
      if (callSite) {
        const cbBody = callSite[0];
        const updatesUI =
          cbBody.includes('renderSessionList') ||
          cbBody.includes('sessionMenuBtn') ||
          cbBody.includes('setStatus') ||
          cbBody.includes('switchSession');
        expect(
          updatesUI,
          'onStateChange callback should trigger UI refresh',
        ).toBe(true);
      } else {
        // If we can't extract the callback, at least verify both symbols exist
        // in close proximity (same init function).
        const hasOnStateChangeAndRender =
          uiSrc.includes('onStateChange') && uiSrc.includes('renderSessionList');
        expect(
          hasOnStateChangeAndRender,
          'ui.ts should use onStateChange to trigger renderSessionList',
        ).toBe(true);
      }
    });
  });

  // ── 5. No duplicate listeners after reconnect (structural) ──────────────

  describe('no duplicate listeners after reconnect', () => {
    it('state.ts reconnecting effect disposes _onDataDisposable', () => {
      // The reconnecting transition effect should dispose the old terminal.onData
      // listener to prevent duplicate output after reconnect.
      // Extract the full reconnecting effect block (may span multiple lines with nested parens)
      const startIdx = stateSrc.indexOf("registerTransitionEffect('reconnecting'");
      expect(startIdx, 'state.ts should have a reconnecting transition effect').toBeGreaterThan(-1);
      // Grab a generous slice to capture the full callback
      const block = stateSrc.slice(startIdx, startIdx + 300);
      expect(
        block,
        'reconnecting effect should dispose _onDataDisposable',
      ).toContain('_onDataDisposable');
    });

    it('connection code tracks _onDataDisposable on the session', () => {
      // Wherever terminal.onData is set up in connection.ts, the disposable
      // should be stored on session._onDataDisposable so the reconnecting
      // effect can clean it up.
      const tracksDisposable =
        connectionSrc.includes('_onDataDisposable') ||
        connectionSrc.includes('onDataDisposable');
      expect(
        tracksDisposable,
        'connection.ts should track _onDataDisposable on the session',
      ).toBe(true);
    });

    it('connection code stores new onData disposable on each connect', () => {
      // Every time terminal.onData is called (on connect or reconnect),
      // the returned IDisposable should be stored on session._onDataDisposable.
      // This ensures the reconnecting effect can dispose the CURRENT listener.
      const onDataAssignment = connectionSrc.match(
        /(?:session\._onDataDisposable|_onDataDisposable)\s*=\s*(?:session\.)?terminal\.onData/,
      );
      expect(
        onDataAssignment,
        'connection.ts should assign terminal.onData disposable to session._onDataDisposable',
      ).toBeTruthy();
    });
  });
});
