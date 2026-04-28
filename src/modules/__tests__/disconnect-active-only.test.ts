/**
 * Disconnect-UI gating — active session only.
 *
 * Bug class: chrome-level UI (toast, status bar, modal, overlay) was firing
 * for every session's disconnect/error events, including backgrounded ones.
 * Result: a session the user wasn't viewing could pop a "Host unreachable"
 * modal over a healthy foreground session, or flip the chrome status to
 * "Disconnected" while the visible session was fine.
 *
 * Fix: gate every chrome UI call after a per-session event on
 * `sessionId === appState.activeSessionId`.
 *
 * This test enforces structurally that the gate is present at each known
 * call site. If a future refactor removes the gate, this test fails
 * before the regression ships.
 */
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const connectionSrc = readFileSync(resolve(__dirname, '../connection.ts'), 'utf-8');

function findHandler(label: string, size = 2500): string {
  const start = connectionSrc.indexOf(label);
  if (start === -1) throw new Error(`handler not found: ${label}`);
  return connectionSrc.slice(start, start + size);
}

describe('disconnect chrome UI gates on active session', () => {
  it("ssh 'error' message handler gates _toast on activeSessionId", () => {
    const block = findHandler("case 'error':");
    // Both branches (connected-and-transient + pre-connect) must check active.
    const errorToasts = block.match(/_toast\(/g) ?? [];
    expect(errorToasts.length).toBeGreaterThan(0);
    const activeChecks = block.match(/sessionId === appState\.activeSessionId/g) ?? [];
    expect(activeChecks.length).toBeGreaterThanOrEqual(errorToasts.length);
  });

  it("ssh 'disconnected' message handler gates _setStatus and _toast", () => {
    const block = findHandler("case 'disconnected':");
    expect(block).toContain('_setStatus');
    expect(block).toContain('_toast');
    // The block needs an active-session gate before either call.
    const setStatusIdx = block.indexOf('_setStatus(');
    const gateIdx = block.indexOf('appState.activeSessionId');
    expect(gateIdx).toBeGreaterThan(-1);
    expect(gateIdx).toBeLessThan(setStatusIdx);
  });

  it("ws 'close' handler gates 'Server busy' / 'Reconnecting…' toasts", () => {
    const block = findHandler("newWs.addEventListener('close'", 4500);
    expect(block).toContain('_toast');
    expect(block).toContain('Server busy');
    // Both _toast call sites must be inside an active-session gate.
    const busyMatch = block.match(/if[^{]*activeSessionId[^}]*Server busy/s);
    expect(busyMatch).not.toBeNull();
    const reconnectingMatch = block.match(/wasSshConnected && sessionId === appState\.activeSessionId/);
    expect(reconnectingMatch).not.toBeNull();
  });

  it('ssh_ready / connected status update gates on activeSessionId', () => {
    // The connected status bar update happens in the ssh 'connected' message
    // handler (logged as ssh_ready). Find it via that log label.
    const start = connectionSrc.indexOf("logConnect('ssh_ready'");
    expect(start).toBeGreaterThan(-1);
    const block = connectionSrc.slice(start, start + 2500);
    expect(block).toContain("_setStatus('connected'");
    // The _setStatus call must be inside an activeSessionId guard.
    const setIdx = block.indexOf("_setStatus('connected'");
    const guardIdx = block.lastIndexOf('activeSessionId', setIdx);
    expect(guardIdx).toBeGreaterThan(-1);
    expect(setIdx - guardIdx).toBeLessThan(200); // guard is on the same logical line/expr
  });

  it('reconnect_halt modal vs toast: dialog only for active, toast for inactive', () => {
    const start = connectionSrc.indexOf('reconnect_halt');
    const block = connectionSrc.slice(start, start + 1500);
    expect(block).toContain('showErrorDialog');
    expect(block).toContain('isActive');
    // Inactive branch must use _toast, not showErrorDialog.
    const inactiveBranch = block.slice(block.indexOf('} else {'));
    expect(inactiveBranch).toContain('_toast');
    expect(inactiveBranch).not.toContain('showErrorDialog');
  });

  it('scheduleReconnect "Reconnecting in Ns…" gates on activeSessionId', () => {
    const start = connectionSrc.indexOf('export function scheduleReconnect');
    const block = connectionSrc.slice(start, start + 2500);
    // The toast and _setStatus pair fires only for active sid.
    const guardIdx = block.indexOf('sid === appState.activeSessionId');
    const reconnectingToastIdx = block.indexOf('Reconnecting in ');
    expect(guardIdx).toBeGreaterThan(-1);
    expect(reconnectingToastIdx).toBeGreaterThan(guardIdx);
  });
});
