/**
 * TDD red baseline for WS transition ordering (#331)
 *
 * The bug: _openWebSocket() assigns session.ws = newWs BEFORE transitioning
 * to 'connecting'. The 'connecting' side-effect nulls handlers on session.ws,
 * which by that point is the NEW WS — killing the connection it just opened.
 *
 * Fix: transition to 'connecting'/'reconnecting' BEFORE assigning session.ws.
 */
import { describe, it, expect, beforeEach, vi } from 'vitest';
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
vi.stubGlobal('location', { hostname: 'localhost' });

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type SessionLike = Record<string, any>;

const { appState, createSession, transitionSession } = await import('../state.js');

const connectionSrc = readFileSync(resolve(__dirname, '../connection.ts'), 'utf-8');

// ---------- Mock helpers ----------

/** Minimal mock WebSocket with assignable handlers. */
function createMockWebSocket(): WebSocket {
  return {
    onopen: null as ((ev: Event) => void) | null,
    onmessage: null as ((ev: MessageEvent) => void) | null,
    onerror: null as ((ev: Event) => void) | null,
    onclose: null as ((ev: CloseEvent) => void) | null,
    close: vi.fn(),
    send: vi.fn(),
    readyState: 1,
    CONNECTING: 0,
    OPEN: 1,
    CLOSING: 2,
    CLOSED: 3,
    url: 'ws://localhost:8081',
    protocol: '',
    extensions: '',
    bufferedAmount: 0,
    binaryType: 'blob' as BinaryType,
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
    dispatchEvent: vi.fn(() => true),
  } as unknown as WebSocket;
}

// ---------- Tests ----------

describe('WS transition ordering (#331)', () => {
  beforeEach(() => {
    appState.sessions.clear();
    appState.activeSessionId = null;
    vi.clearAllMocks();
  });

  // 1. Prove the connecting effect nulls handlers on session.ws — so ordering matters
  it('connecting effect nulls handlers on session.ws (ordering matters)', () => {
    const session = createSession('order-1') as SessionLike;
    const ws = createMockWebSocket();
    ws.onopen = () => {};
    ws.onmessage = () => {};
    ws.onerror = () => {};
    ws.onclose = () => {};
    session.ws = ws;

    // If transition fires while session.ws points to this WS, handlers get nulled
    transitionSession('order-1', 'connecting');

    expect(ws.onopen).toBeNull();
    expect(ws.onmessage).toBeNull();
    expect(ws.onerror).toBeNull();
    expect(ws.onclose).toBeNull();
  });

  // 2. Connecting effect cleans up old WS before new one is assigned
  it('connecting effect cleans up old WS, new WS handlers survive', () => {
    const session = createSession('order-2') as SessionLike;
    const oldWs = createMockWebSocket();
    oldWs.onopen = () => {};
    oldWs.onmessage = () => {};
    oldWs.onerror = () => {};
    oldWs.onclose = () => {};
    session.ws = oldWs;

    // Transition to connecting — should clean up old WS
    transitionSession('order-2', 'connecting');

    // Old WS handlers should be nulled by the effect
    expect(oldWs.onmessage).toBeNull();
    expect(oldWs.onerror).toBeNull();
    expect(oldWs.onclose).toBeNull();
    expect(oldWs.onopen).toBeNull();

    // Now assign new WS — its handlers should be intact
    const newWs = createMockWebSocket();
    const handler = () => {};
    newWs.onopen = handler;
    newWs.onmessage = handler;
    session.ws = newWs;

    expect(newWs.onopen).toBe(handler);
    expect(newWs.onmessage).toBe(handler);
  });

  // 3. Source-structural: transitionSession 'connecting' appears BEFORE session.ws = newWs
  it('transitionSession connecting is called before session.ws = newWs in source', () => {
    // Find the _openWebSocket function body
    const fnStart = connectionSrc.indexOf('function _openWebSocket');
    expect(fnStart).toBeGreaterThan(-1);

    const fnBody = connectionSrc.slice(fnStart);

    // The transition to 'connecting' should appear BEFORE the ws assignment
    const transitionConnecting = fnBody.indexOf("transitionSession(sessionId, 'connecting')");
    const wsAssignment = fnBody.indexOf('session.ws = newWs');

    expect(transitionConnecting).toBeGreaterThan(-1);
    expect(wsAssignment).toBeGreaterThan(-1);
    expect(transitionConnecting).toBeLessThan(wsAssignment);
  });

  // 4. Source-structural: transitionSession 'reconnecting' appears BEFORE WS assignment
  it('transitionSession reconnecting is called before session.ws = newWs in source', () => {
    const fnStart = connectionSrc.indexOf('function _openWebSocket');
    expect(fnStart).toBeGreaterThan(-1);

    const fnBody = connectionSrc.slice(fnStart);

    const transitionReconnecting = fnBody.indexOf("transitionSession(sessionId, 'reconnecting')");
    const wsAssignment = fnBody.indexOf('session.ws = newWs');

    expect(transitionReconnecting).toBeGreaterThan(-1);
    expect(wsAssignment).toBeGreaterThan(-1);
    expect(transitionReconnecting).toBeLessThan(wsAssignment);
  });

  // 5. Auth message sent in onopen without transition interference
  it('onopen handler survives after transition + ws assignment sequence', () => {
    const session = createSession('order-5') as SessionLike;

    // Correct ordering: transition FIRST, then assign WS
    transitionSession('order-5', 'connecting');

    const newWs = createMockWebSocket();
    const onopen = vi.fn();
    newWs.onopen = onopen;
    newWs.onmessage = vi.fn();
    session.ws = newWs;

    // The onopen handler should still be there — not nulled by any effect
    expect(newWs.onopen).toBe(onopen);

    // Simulate WS open event — handler should fire
    newWs.onopen!(new Event('open'));
    expect(onopen).toHaveBeenCalledTimes(1);
  });
});
