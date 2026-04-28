/**
 * Smoketest: SessionHandle wiring into the app (#374)
 *
 * Verifies that connection.ts uses SessionHandle for session creation
 * and that ui.ts uses SessionHandle show/hide/fitIfVisible instead of
 * the old triple-fit pattern.
 */
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const connectionSrc = readFileSync(resolve(__dirname, '../connection.ts'), 'utf-8');
const uiSrc = readFileSync(resolve(__dirname, '../ui.ts'), 'utf-8');
const appSrc = readFileSync(resolve(__dirname, '../../app.ts'), 'utf-8');
const terminalSrc = readFileSync(resolve(__dirname, '../terminal.ts'), 'utf-8');

describe('SessionHandle wiring (#374)', () => {
  describe('connection.ts', () => {
    it('imports SessionHandle from session.ts', () => {
      expect(connectionSrc).toContain("import { SessionHandle } from './session.js'");
    });

    it('creates SessionHandle instances for new sessions', () => {
      expect(connectionSrc).toMatch(/new\s+SessionHandle\s*\(/);
    });

    it('exports getSessionHandle for other modules', () => {
      expect(connectionSrc).toMatch(/export\s+function\s+getSessionHandle/);
    });

    it('exports removeSessionHandle for cleanup', () => {
      expect(connectionSrc).toMatch(/export\s+function\s+removeSessionHandle/);
    });

    it('visibilitychange reconnects sessions and probes zombies instead of fitting', () => {
      // The handler reconnects dropped sessions (active immediate, others 3s delay)
      // and calls _probeZombieConnection() for open WS sessions. No fitIfVisible.
      const visStart = connectionSrc.indexOf("document.addEventListener('visibilitychange'");
      const visBlock = connectionSrc.slice(visStart, visStart + 2600);
      expect(visBlock).toContain('_probeZombieConnection');
      expect(visBlock).toContain('_openWebSocket');
      // No fitIfVisible or fitAddon.fit in the visibility handler
      expect(visBlock).not.toContain('fitIfVisible');
      expect(visBlock).not.toMatch(/fitAddon\.fit/);
    });
  });

  describe('ui.ts', () => {
    it('imports getSessionHandle from connection.ts', () => {
      expect(uiSrc).toContain('getSessionHandle');
    });

    it('imports removeSessionHandle from connection.ts', () => {
      expect(uiSrc).toContain('removeSessionHandle');
    });

    it('switchSession uses handle.show/hide instead of classList.toggle', () => {
      const switchStart = uiSrc.indexOf('export function switchSession');
      const switchEnd = uiSrc.indexOf('\nexport function', switchStart + 1);
      const switchFn = uiSrc.slice(switchStart, switchEnd > 0 ? switchEnd : switchStart + 2500);
      expect(switchFn).toContain('.show()');
      expect(switchFn).toContain('.hide()');
    });

    it('switchSession does unconditional reconnect instead of fitIfVisible', () => {
      const switchStart = uiSrc.indexOf('export function switchSession');
      const switchEnd = uiSrc.indexOf('\nexport function', switchStart + 1);
      const switchFn = uiSrc.slice(switchStart, switchEnd > 0 ? switchEnd : switchStart + 2000);
      // switchSession reconnects when not connected — no explicit fit call
      expect(switchFn).toContain('reconnect');
      expect(switchFn).not.toContain('fitIfVisible');
      expect(switchFn).not.toContain('requestAnimationFrame(doFit)');
    });

    it('navigateToPanel uses handle.fit() instead of setTimeout chain', () => {
      const navStart = uiSrc.indexOf('export function navigateToPanel');
      const navEnd = uiSrc.indexOf('\nexport function', navStart + 1);
      const navFn = uiSrc.slice(navStart, navEnd > 0 ? navEnd : navStart + 1500);
      expect(navFn).toContain('handle.fit()');
      expect(navFn).not.toContain('fitIfVisible');
      expect(navFn).not.toContain('setTimeout(fitAndRefresh, 500)');
    });

    it('does not export initTerminalResizeObserver', () => {
      expect(uiSrc).not.toMatch(/export\s+function\s+initTerminalResizeObserver/);
    });

    it('closeSession calls removeSessionHandle', () => {
      const closeStart = uiSrc.indexOf('export function closeSession');
      const closeEnd = uiSrc.indexOf('\nexport function', closeStart + 1);
      const closeFn = uiSrc.slice(closeStart, closeEnd > 0 ? closeEnd : closeStart + 1500);
      expect(closeFn).toContain('removeSessionHandle');
    });
  });

  describe('app.ts', () => {
    it('does not import initTerminalResizeObserver', () => {
      expect(appSrc).not.toContain('initTerminalResizeObserver');
    });
  });

  describe('terminal.ts', () => {
    it('exports setSessionHandleLookup for DI wiring', () => {
      expect(terminalSrc).toMatch(/export\s+function\s+setSessionHandleLookup/);
    });

    it('handleResize is a no-op (terminals resize via ResizeObserver)', () => {
      const handleStart = terminalSrc.indexOf('export function handleResize');
      const handleEnd = terminalSrc.indexOf('}', handleStart);
      const handleFn = terminalSrc.slice(handleStart, handleEnd + 1);
      // handleResize is now a no-op — no fit, no delegate
      expect(handleFn).not.toContain('fitIfVisible');
      expect(handleFn).not.toContain('fitAddon');
      expect(handleFn).toContain('No-op');
    });
  });
});
