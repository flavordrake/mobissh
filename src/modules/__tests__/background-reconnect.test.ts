/**
 * TDD tests for background session auto-reconnect (#354).
 *
 * Bug: _probeZombieConnection only probes currentSession(), not all sessions.
 * The visibilitychange handler iterates all sessions but only reconnects those
 * with closed WS — sessions with zombie WS (OPEN but SSH dead) are missed.
 *
 * These tests express the expected behavior and should FAIL against the
 * current code.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { readFileSync } from 'fs';
import { resolve } from 'path';

const connectionSrc = readFileSync(resolve(__dirname, '../connection.ts'), 'utf-8');

/** Extract a function body from source, handling type annotations. */
function extractFnBody(src: string, fnName: string): string {
  const fnStart = src.indexOf(fnName);
  if (fnStart === -1) return '';
  const sigEnd = src.indexOf('{', src.indexOf(')', fnStart));
  if (sigEnd === -1) return '';
  let depth = 0, fnEnd = sigEnd;
  for (let i = sigEnd; i < src.length; i++) {
    if (src[i] === '{') depth++;
    if (src[i] === '}') depth--;
    if (depth === 0) { fnEnd = i + 1; break; }
  }
  return src.slice(fnStart, fnEnd);
}

// ── Structural tests: verify source code iterates all sessions ──

describe('Background reconnect — structural (#354)', () => {

  describe('_probeZombieConnection probes all sessions', () => {
    it('iterates appState.sessions, not just currentSession()', () => {
      const body = extractFnBody(connectionSrc, 'function _probeZombieConnection');
      expect(body.length).toBeGreaterThan(50);
      // The function should iterate over all sessions (for..of or forEach on sessions map)
      const iteratesSessions = body.includes('appState.sessions') &&
        (body.match(/for\s*\(/) || body.includes('.forEach'));
      expect(iteratesSessions).toBeTruthy();
    });

    it('does not use currentSession() as its only session source', () => {
      const body = extractFnBody(connectionSrc, 'function _probeZombieConnection');
      expect(body.length).toBeGreaterThan(50);
      // Current buggy code: `const sessionWs = currentSession()?.ws;`
      // Fixed code should iterate appState.sessions, not just call currentSession
      const usesCurrentSession = body.includes('currentSession()');
      const iteratesSessions = body.includes('appState.sessions');
      // Must iterate the sessions map; relying solely on currentSession is the bug
      expect(iteratesSessions).toBe(true);
      if (usesCurrentSession) {
        // If it still calls currentSession(), it must ALSO iterate all sessions
        expect(iteratesSessions).toBe(true);
      }
    });
  });

  describe('visibilitychange handler probes open sessions', () => {
    it('calls _probeZombieConnection (or equivalent probe) for sessions with open WS', () => {
      // Find the visibilitychange handler block
      const visStart = connectionSrc.indexOf("document.addEventListener('visibilitychange'");
      expect(visStart).toBeGreaterThan(-1);
      // Extract the handler body (look for the next ~1500 chars which covers the handler)
      const visBlock = connectionSrc.slice(visStart, visStart + 2400);

      // The else branch (WS is OPEN) should probe, not just send a simple ping
      // Current buggy code just does: session.ws.send(JSON.stringify({ type: 'ping' }))
      // Fixed code should call _probeZombieConnection or equivalent for each session
      const hasProbeCall = visBlock.includes('_probeZombieConnection') ||
        visBlock.match(/probe.*session/i) ||
        // Or the handler itself implements per-session zombie detection with timeout
        (visBlock.includes('setTimeout') && visBlock.includes('close'));

      expect(hasProbeCall).toBeTruthy();
    });

    it('does not just send a keepalive ping to sessions with open WS', () => {
      const visStart = connectionSrc.indexOf("document.addEventListener('visibilitychange'");
      expect(visStart).toBeGreaterThan(-1);
      const visBlock = connectionSrc.slice(visStart, visStart + 2400);

      // Find the else branch for OPEN WS sessions
      // Current buggy code: `try { session.ws.send(JSON.stringify({ type: 'ping' })); } catch { /* ignore */ }`
      // This is insufficient — a simple ping without timeout detection won't catch zombie connections
      // The else branch should NOT be just a fire-and-forget ping
      const elseMatch = visBlock.match(/else\s*\{[^}]*?ping[^}]*?\}/s);
      if (elseMatch) {
        const elseBranch = elseMatch[0];
        // The else branch should contain timeout/probe logic, not just a blind send
        const hasTimeoutLogic = elseBranch.includes('setTimeout') ||
          elseBranch.includes('_probeZombieConnection') ||
          elseBranch.includes('probe');
        expect(hasTimeoutLogic).toBeTruthy();
      }
      // If no simple else branch found, the code may have been restructured (good)
    });
  });
});

// ── Behavioral tests: mock multiple sessions and verify all are probed ──

import { webcrypto } from 'node:crypto';

vi.stubGlobal('crypto', webcrypto);

const storage = new Map<string, string>();
vi.stubGlobal('localStorage', {
  getItem: (key: string) => storage.get(key) ?? null,
  setItem: (key: string, value: string) => { storage.set(key, value); },
  removeItem: (key: string) => { storage.delete(key); },
  clear: () => { storage.clear(); },
  get length() { return storage.size; },
  key: (_i: number) => null as string | null,
});
vi.stubGlobal('location', { hostname: 'localhost' });

let visibilityHandler: (() => void) | null = null;
let _visibilityState = 'visible';

const mockErrorOverlay = {
  classList: { add: vi.fn(), remove: vi.fn() },
};

vi.stubGlobal('document', {
  getElementById: (id: string) => {
    if (id === 'errorDialogOverlay') return mockErrorOverlay;
    return null;
  },
  querySelector: () => null,
  addEventListener: (event: string, handler: () => void) => {
    if (event === 'visibilitychange') visibilityHandler = handler;
  },
  get visibilityState() { return _visibilityState; },
  createElement: vi.fn(() => ({
    className: '',
    textContent: '',
    innerHTML: '',
    id: '',
    appendChild: vi.fn(),
    addEventListener: vi.fn(),
    querySelector: vi.fn(),
    remove: vi.fn(),
  })),
  body: { appendChild: vi.fn() },
});

let wsInstances: Array<{
  onopen: ((e?: unknown) => void) | null;
  onclose: ((e?: unknown) => void) | null;
  onmessage: ((e?: unknown) => void) | null;
  onerror: ((e?: unknown) => void) | null;
  readyState: number;
  url: string;
  close: ReturnType<typeof vi.fn>;
  send: ReturnType<typeof vi.fn>;
}> = [];

vi.stubGlobal('WebSocket', class {
  onopen: ((e?: unknown) => void) | null = null;
  onclose: ((e?: unknown) => void) | null = null;
  onmessage: ((e?: unknown) => void) | null = null;
  onerror: ((e?: unknown) => void) | null = null;
  readyState = 1;
  url: string;
  close = vi.fn();
  send = vi.fn();
  addEventListener = vi.fn();
  removeEventListener = vi.fn();
  static OPEN = 1;
  static CLOSED = 3;
  static CLOSING = 2;
  constructor(url: string) {
    this.url = url;
    // eslint-disable-next-line @typescript-eslint/no-this-alias
    wsInstances.push(this);
  }
});
vi.stubGlobal('Worker', class { onmessage = null; postMessage = vi.fn(); terminate = vi.fn(); });
vi.stubGlobal('navigator', { wakeLock: undefined });
vi.stubGlobal('window', {
  addEventListener: vi.fn(),
  location: { protocol: 'http:', host: 'localhost:8081', pathname: '/' },
});

vi.useFakeTimers();

const { cancelReconnect, _probeZombieConnection } = await import('../connection.js');
const { appState, createSession, transitionSession } = await import('../state.js');

const TEST_PROFILE = { name: 'test', host: 'test', port: 22, username: 'test', authType: 'password' as const };

function makeFakeWs(overrides?: Partial<{ readyState: number }>) {
  return {
    readyState: overrides?.readyState ?? 1, // OPEN
    url: 'ws://localhost:8081',
    send: vi.fn(),
    close: vi.fn(),
    onopen: null as ((e?: unknown) => void) | null,
    onclose: null as ((e?: unknown) => void) | null,
    onmessage: null as ((e?: unknown) => void) | null,
    onerror: null as ((e?: unknown) => void) | null,
  };
}

describe('Background reconnect — behavioral (#354)', () => {
  beforeEach(() => {
    // Flush pending probe timers so _zombieProbeTimers map is cleaned up
    vi.runAllTimers();
    storage.clear();
    appState.sessions.clear();
    appState.activeSessionId = null;
    appState.hasConnected = false;
    _visibilityState = 'visible';
    wsInstances = [];
    mockErrorOverlay.classList.add.mockClear();
  });

  it('zombie probe covers all sessions, not just current', () => {
    // Create two sessions, both with open WS
    const session1 = createSession('session-1');
    session1.profile = TEST_PROFILE;
    const ws1 = makeFakeWs();
    session1.ws = ws1 as unknown as WebSocket;
    transitionSession('session-1', 'connecting');
    transitionSession('session-1', 'authenticating');
    transitionSession('session-1', 'connected');

    const session2 = createSession('session-2');
    session2.profile = TEST_PROFILE;
    const ws2 = makeFakeWs();
    session2.ws = ws2 as unknown as WebSocket;
    transitionSession('session-2', 'connecting');
    transitionSession('session-2', 'authenticating');
    transitionSession('session-2', 'connected');

    // Set session-1 as active — session-2 is "background"
    appState.activeSessionId = 'session-1';

    // Call _probeZombieConnection — should probe ALL sessions
    _probeZombieConnection();

    // Both sessions should have received a ping probe
    expect(ws1.send).toHaveBeenCalledWith(JSON.stringify({ type: 'ping' }));
    expect(ws2.send).toHaveBeenCalledWith(JSON.stringify({ type: 'ping' }));
  });

  it('background session with zombie WS gets force-closed after timeout', () => {
    // Create two sessions
    const session1 = createSession('session-1');
    session1.profile = TEST_PROFILE;
    const ws1 = makeFakeWs();
    session1.ws = ws1 as unknown as WebSocket;
    transitionSession('session-1', 'connecting');
    transitionSession('session-1', 'authenticating');
    transitionSession('session-1', 'connected');

    const session2 = createSession('session-2');
    session2.profile = TEST_PROFILE;
    const ws2 = makeFakeWs();
    session2.ws = ws2 as unknown as WebSocket;
    transitionSession('session-2', 'connecting');
    transitionSession('session-2', 'authenticating');
    transitionSession('session-2', 'connected');

    appState.activeSessionId = 'session-1';

    // Trigger visibilitychange (resume from background)
    _visibilityState = 'hidden';
    visibilityHandler?.();
    _visibilityState = 'visible';
    visibilityHandler?.();

    // Advance past probe timeout (5s) — both zombie WS should be force-closed
    vi.advanceTimersByTime(5000);

    // Background session's zombie WS should be force-closed
    expect(ws2.close).toHaveBeenCalled();
  });

  it('visibilitychange probes all sessions with open WS', () => {
    // Create two sessions with open WS
    const session1 = createSession('session-1');
    session1.profile = TEST_PROFILE;
    const ws1 = makeFakeWs();
    session1.ws = ws1 as unknown as WebSocket;
    transitionSession('session-1', 'connecting');
    transitionSession('session-1', 'authenticating');
    transitionSession('session-1', 'connected');

    const session2 = createSession('session-2');
    session2.profile = TEST_PROFILE;
    const ws2 = makeFakeWs();
    session2.ws = ws2 as unknown as WebSocket;
    transitionSession('session-2', 'connecting');
    transitionSession('session-2', 'authenticating');
    transitionSession('session-2', 'connected');

    appState.activeSessionId = 'session-1';

    // Resume from background
    _visibilityState = 'visible';
    visibilityHandler?.();

    // Both sessions should be probed (not just pinged)
    // A probe means: send ping AND set up a timeout to force-close if no response
    expect(ws1.send).toHaveBeenCalledWith(JSON.stringify({ type: 'ping' }));
    expect(ws2.send).toHaveBeenCalledWith(JSON.stringify({ type: 'ping' }));

    // Verify probe timeout is set for background session too
    // If no response arrives within 5s, both should be force-closed
    vi.advanceTimersByTime(5000);
    expect(ws1.close).toHaveBeenCalled();
    expect(ws2.close).toHaveBeenCalled();
  });

  it('session with closed WS still gets reconnected (regression guard)', () => {
    // Create a session with no WS (dropped connection)
    const session1 = createSession('session-1');
    session1.profile = TEST_PROFILE;
    session1.ws = null;

    appState.activeSessionId = 'session-1';

    // Resume from background
    _visibilityState = 'hidden';
    visibilityHandler?.();
    _visibilityState = 'visible';
    visibilityHandler?.();

    // Should have created a new WebSocket (reconnect attempt)
    expect(wsInstances.length).toBeGreaterThan(0);
  });

  it('session without profile is skipped during probe', () => {
    // Create a session WITHOUT a profile
    const session1 = createSession('session-no-profile');
    // No profile set
    const ws1 = makeFakeWs();
    session1.ws = ws1 as unknown as WebSocket;

    // Create a session WITH a profile
    const session2 = createSession('session-with-profile');
    session2.profile = TEST_PROFILE;
    const ws2 = makeFakeWs();
    session2.ws = ws2 as unknown as WebSocket;
    transitionSession('session-with-profile', 'connecting');
    transitionSession('session-with-profile', 'authenticating');
    transitionSession('session-with-profile', 'connected');

    appState.activeSessionId = 'session-with-profile';

    // Resume from background
    _visibilityState = 'visible';
    visibilityHandler?.();

    // Session without profile should NOT be probed
    expect(ws1.send).not.toHaveBeenCalled();
    // Session with profile should be probed
    expect(ws2.send).toHaveBeenCalled();
  });

  it('probe response cancels force-close for background session', () => {
    // Create two sessions
    const session1 = createSession('session-1');
    session1.profile = TEST_PROFILE;
    const ws1 = makeFakeWs();
    session1.ws = ws1 as unknown as WebSocket;
    transitionSession('session-1', 'connecting');
    transitionSession('session-1', 'authenticating');
    transitionSession('session-1', 'connected');

    const session2 = createSession('session-2');
    session2.profile = TEST_PROFILE;
    const ws2 = makeFakeWs();
    session2.ws = ws2 as unknown as WebSocket;
    transitionSession('session-2', 'connecting');
    transitionSession('session-2', 'authenticating');
    transitionSession('session-2', 'connected');

    appState.activeSessionId = 'session-1';

    // Resume from background — should start probe on all sessions
    _visibilityState = 'visible';
    visibilityHandler?.();

    // The probe must have wrapped onmessage on the background session's WS.
    // A proper zombie probe installs an onmessage wrapper to detect responses.
    // The current code only does a fire-and-forget ping — no wrapper, no timeout.
    // Verify that a probe handler was installed on the background session.
    expect(ws2.onmessage).not.toBeNull();

    // Background session responds to probe — connection is alive
    ws2.onmessage!({ data: JSON.stringify({ type: 'pong' }) });

    // Advance past probe timeout
    vi.advanceTimersByTime(5000);

    // Background session should NOT be force-closed (it responded in time)
    expect(ws2.close).not.toHaveBeenCalled();
  });
});
