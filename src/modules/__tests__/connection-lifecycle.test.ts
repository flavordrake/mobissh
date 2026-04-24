/**
 * TDD red baseline for AbortController-based connection lifecycle cleanup (#334)
 *
 * Three bugs exist in the current code:
 * 1. onStateChange subscriber leaks — registered inside closeSession() (ui.ts:361),
 *    adds a new subscriber on every close call
 * 2. terminal.onData not re-registered after reconnect — disposed on reconnecting
 *    effect, never recreated
 * 3. WS handlers use .onmessage = property assignment — fragile, no automatic cleanup
 *
 * The fix introduces a ConnectionCycle with AbortController + DisposableGroup per session.
 *
 * All tests should FAIL on current main and PASS when #334 is implemented.
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

const { appState, createSession, transitionSession, onStateChange } = await import('../state.js');

const uiSrc = readFileSync(resolve(__dirname, '../ui.ts'), 'utf-8');
const connectionSrc = readFileSync(resolve(__dirname, '../connection.ts'), 'utf-8');

/** Extract a function body from source, handling type annotations in params. */
function extractFnBody(src: string, fnName: string): string {
  const fnStart = src.indexOf(fnName);
  if (fnStart === -1) return '';
  // Find the opening brace of the function body (skip type annotations in params)
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

// ---------- Mock helpers ----------

/** Minimal mock WebSocket with addEventListener tracking. */
function createMockWebSocket(): WebSocket & { _listeners: Map<string, Array<{ handler: EventListener; signal?: AbortSignal }>> } {
  const listeners = new Map<string, Array<{ handler: EventListener; signal?: AbortSignal }>>();

  const ws = {
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
    _listeners: listeners,
    addEventListener: vi.fn((type: string, handler: EventListener, opts?: AddEventListenerOptions) => {
      if (!listeners.has(type)) listeners.set(type, []);
      listeners.get(type)!.push({ handler, signal: opts?.signal });
    }),
    removeEventListener: vi.fn((type: string, handler: EventListener) => {
      const list = listeners.get(type);
      if (list) {
        const idx = list.findIndex((e) => e.handler === handler);
        if (idx >= 0) list.splice(idx, 1);
      }
    }),
    dispatchEvent: vi.fn(() => true),
  } as unknown as WebSocket & { _listeners: Map<string, Array<{ handler: EventListener; signal?: AbortSignal }>> };
  return ws;
}

/** Minimal mock terminal with onData disposable. */
function createMockTerminal() {
  const onDataDisposable = { dispose: vi.fn() };
  return {
    onData: vi.fn(() => onDataDisposable),
    onDataDisposable,
    dispose: vi.fn(),
    write: vi.fn(),
    clear: vi.fn(),
    reset: vi.fn(),
  };
}

/** Drive a session through the happy path to the given state. */
function driveToState(id: string, target: 'connecting' | 'authenticating' | 'connected' | 'soft_disconnected' | 'reconnecting') {
  const order = ['connecting', 'authenticating', 'connected', 'soft_disconnected', 'reconnecting'] as const;
  for (const s of order) {
    transitionSession(id, s);
    if (s === target) break;
  }
}

// ---------- Tests ----------

describe('AbortController connection lifecycle cleanup (#334)', () => {
  beforeEach(() => {
    appState.sessions.clear();
    appState.activeSessionId = null;
    vi.clearAllMocks();
    vi.useRealTimers();
  });

  // ── 1. onStateChange subscriber leak (source-structural) ─────────────

  describe('onStateChange subscriber leak', () => {
    it('onStateChange is NOT called inside closeSession function body', () => {
      // Extract closeSession function body from ui.ts source
      const fnMatch = uiSrc.match(/(?:export\s+)?function\s+closeSession\s*\([^)]*\)\s*(?::\s*\w+\s*)?\{/);
      expect(fnMatch).not.toBeNull();

      const fnStart = uiSrc.indexOf(fnMatch![0]);
      // Find the matching closing brace by counting braces
      let depth = 0;
      let fnEnd = fnStart;
      let started = false;
      for (let i = fnStart; i < uiSrc.length; i++) {
        if (uiSrc[i] === '{') { depth++; started = true; }
        if (uiSrc[i] === '}') { depth--; }
        if (started && depth === 0) { fnEnd = i + 1; break; }
      }
      const closeSessionBody = uiSrc.slice(fnStart, fnEnd);

      // onStateChange should NOT appear inside closeSession
      expect(closeSessionBody).not.toContain('onStateChange');
    });

    it('onStateChange IS called inside initSessionMenu (one-time registration)', () => {
      // The onStateChange UI subscriber should be registered once in initSessionMenu,
      // not repeatedly in closeSession
      const fnMatch = uiSrc.match(/(?:export\s+)?function\s+initSessionMenu\s*\([^)]*\)\s*(?::\s*\w+\s*)?\{/);
      expect(fnMatch).not.toBeNull();

      const fnStart = uiSrc.indexOf(fnMatch![0]);
      let depth = 0;
      let fnEnd = fnStart;
      let started = false;
      for (let i = fnStart; i < uiSrc.length; i++) {
        if (uiSrc[i] === '{') { depth++; started = true; }
        if (uiSrc[i] === '}') { depth--; }
        if (started && depth === 0) { fnEnd = i + 1; break; }
      }
      const initSessionMenuBody = uiSrc.slice(fnStart, fnEnd);

      expect(initSessionMenuBody).toContain('onStateChange');
    });
  });

  // ── 2. AbortController per connection cycle (source-structural + runtime) ──

  describe('AbortController per connection cycle', () => {
    it('uses addEventListener (not .onmessage =) for WS message handlers in _openWebSocket', () => {
      // Extract _openWebSocket function body
      const fnStart = connectionSrc.indexOf('function _openWebSocket');
      expect(fnStart).toBeGreaterThan(-1);

      // Find the function body opening brace (skip type annotations in params)
      const bodyStart = connectionSrc.indexOf('{\n', connectionSrc.indexOf('): void', fnStart));
      let depth = 0;
      let fnEnd = bodyStart;
      for (let i = bodyStart; i < connectionSrc.length; i++) {
        if (connectionSrc[i] === '{') depth++;
        if (connectionSrc[i] === '}') depth--;
        if (depth === 0) { fnEnd = i + 1; break; }
      }
      const fnBody = connectionSrc.slice(fnStart, fnEnd);

      // Should use addEventListener, not property assignment for message/close/error
      expect(fnBody).toContain('addEventListener');
      expect(fnBody).not.toMatch(/newWs\.onmessage\s*=/);
      expect(fnBody).not.toMatch(/newWs\.onclose\s*=/);
      expect(fnBody).not.toMatch(/newWs\.onerror\s*=/);
    });

    it('passes AbortController signal to addEventListener in _openWebSocket', () => {
      const fnBody = extractFnBody(connectionSrc, 'function _openWebSocket');
      expect(fnBody.length).toBeGreaterThan(100);
      const hasAbortController = fnBody.includes('AbortController');
      const hasSignal = fnBody.includes('signal');
      expect(hasAbortController || hasSignal).toBe(true);
    });

    it('aborts previous cycle controller before creating new WS', () => {
      const fnBody = extractFnBody(connectionSrc, 'function _openWebSocket');
      expect(fnBody.length).toBeGreaterThan(100);
      const hasAbort = fnBody.includes('.abort()');
      const hasCycleCleanup = fnBody.includes('_cycle') || fnBody.includes('cycle.dispose') || fnBody.includes('cycle.abort');
      expect(hasAbort || hasCycleCleanup).toBe(true);
    });
  });

  // ── 3. terminal.onData re-registration after reconnect (source-structural) ──

  describe('terminal.onData re-registration after reconnect', () => {
    it('terminal.onData registration appears in _openWebSocket or connected effect (not just connect)', () => {
      const openWsBody = extractFnBody(connectionSrc, 'function _openWebSocket');
      expect(openWsBody.length).toBeGreaterThan(100);
      const inOpenWs = openWsBody.includes('terminal.onData') || openWsBody.includes('.onData(');
      const connectedEffectPattern = /registerTransitionEffect\s*\(\s*['"]connected['"]/;
      const hasConnectedEffect = connectedEffectPattern.test(connectionSrc);
      expect(inOpenWs || hasConnectedEffect).toBe(true);
    });

    it('onData disposable is tracked in a cycle/group, not just session._onDataDisposable', () => {
      // The old pattern stores the disposable directly on the session object.
      // The new pattern should track it in a ConnectionCycle/DisposableGroup
      // so it gets auto-disposed when the cycle ends.

      // Look for connect() function where terminal.onData is first registered
      const connectFn = connectionSrc.indexOf('function connect(');
      if (connectFn === -1) {
        // Maybe it's exported differently; check for the terminal.onData pattern
        const onDataLine = connectionSrc.indexOf('terminal.onData');
        expect(onDataLine).toBeGreaterThan(-1);
      }

      // The disposable should NOT be stored as session._onDataDisposable alone
      // It should be part of a cycle/group tracking mechanism
      const hasCycleTracking = connectionSrc.includes('_cycle') ||
        connectionSrc.includes('DisposableGroup') ||
        connectionSrc.includes('ConnectionCycle') ||
        connectionSrc.includes('cycle.track') ||
        connectionSrc.includes('group.add');

      expect(hasCycleTracking).toBe(true);
    });
  });

  // ── 4. Full lifecycle: connect -> disconnect -> reconnect -> no duplicate handlers ──

  describe('full lifecycle: connect -> disconnect -> reconnect -> no duplicate handlers', () => {
    it('reconnecting effect aborts the previous cycle controller', () => {
      const session = createSession('lifecycle-abort') as SessionLike;
      const term = createMockTerminal();
      session.terminal = term;

      // Simulate first connection with AbortController
      const controller1 = new AbortController();
      const abortSpy = vi.spyOn(controller1, 'abort');

      session.ws = createMockWebSocket();
      // ConnectionCycle shape (types.ts): { controller, disposables: Disposable[] }.
      // abortCycle() iterates disposables, so the fixture must supply the array.
      session._cycle = { controller: controller1, disposables: [] };

      driveToState('lifecycle-abort', 'connected');

      // Soft disconnect -> reconnect
      transitionSession('lifecycle-abort', 'soft_disconnected');
      transitionSession('lifecycle-abort', 'reconnecting');

      // The reconnecting effect should abort the old cycle's controller
      // so all addEventListener listeners with that signal get auto-removed
      expect(abortSpy).toHaveBeenCalled();
    });

    it('after full cycle only one terminal.onData is active', () => {
      const session = createSession('lifecycle-ondata') as SessionLike;
      const term = createMockTerminal();
      session.terminal = term;

      const disposable1 = { dispose: vi.fn() };
      session._onDataDisposable = disposable1;

      // First connection
      driveToState('lifecycle-ondata', 'connected');

      // Soft disconnect -> reconnect
      transitionSession('lifecycle-ondata', 'soft_disconnected');
      transitionSession('lifecycle-ondata', 'reconnecting');

      // Old disposable should be disposed
      expect(disposable1.dispose).toHaveBeenCalled();

      // Old disposable disposed, ready for _openWebSocket to register a new one.
      // The actual re-registration happens in _openWebSocket (verified by structural test),
      // not in the connected effect. Here we verify the cleanup side is correct.
      transitionSession('lifecycle-ondata', 'connected');

      // Old disposable was disposed during reconnecting
      expect(disposable1.dispose).toHaveBeenCalledTimes(1);
    });
  });

  // ── 5. closeSession disposes cycle ──

  describe('closeSession disposes cycle', () => {
    it('transitioning to closed aborts the connection cycle controller', () => {
      const session = createSession('close-cycle') as SessionLike;
      const controller = new AbortController();
      const abortSpy = vi.spyOn(controller, 'abort');

      // Attach a mock cycle to the session. abortCycle() iterates disposables,
      // so include the array (ConnectionCycle contract from types.ts).
      session._cycle = { controller, disposables: [], abort: () => controller.abort() };
      session.ws = createMockWebSocket();
      session.terminal = createMockTerminal();

      // Transition to closed
      transitionSession('close-cycle', 'closed');

      // The controller should have been aborted
      expect(abortSpy).toHaveBeenCalled();
    });

    it('transitioning to closed disposes all tracked disposables', () => {
      const session = createSession('close-disposables') as SessionLike;
      const disposable1 = { dispose: vi.fn() };
      const disposable2 = { dispose: vi.fn() };

      // Attach a mock cycle with tracked disposables
      session._cycle = {
        controller: new AbortController(),
        disposables: [disposable1, disposable2],
        dispose: () => {
          disposable1.dispose();
          disposable2.dispose();
        },
      };
      session.ws = createMockWebSocket();
      session.terminal = createMockTerminal();

      transitionSession('close-disposables', 'closed');

      // All tracked disposables should be disposed
      expect(disposable1.dispose).toHaveBeenCalled();
      expect(disposable2.dispose).toHaveBeenCalled();
    });
  });
});
