/**
 * TDD red baseline for session state machine side-effects (#322)
 *
 * The current transitionSession() only updates session.state and validates
 * transitions. These tests express the EXPECTED side-effect behavior that
 * will be added: cleanup, listener disposal, timer management, and UI
 * notification on state transitions.
 *
 * All tests should FAIL on current main and PASS when #322 is implemented.
 */
import { describe, it, expect, beforeEach, vi } from 'vitest';

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
type StateModule = Record<string, any>;

const stateModule = await import('../state.js') as StateModule;
const { appState, createSession, transitionSession } = stateModule;

// ---------- Mock helpers ----------

/** Minimal mock WebSocket with assignable handlers and state tracking. */
function createMockWebSocket(): WebSocket {
  const ws = {
    onopen: null as ((ev: Event) => void) | null,
    onmessage: null as ((ev: MessageEvent) => void) | null,
    onerror: null as ((ev: Event) => void) | null,
    onclose: null as ((ev: CloseEvent) => void) | null,
    close: vi.fn(),
    send: vi.fn(),
    readyState: 1, // WebSocket.OPEN
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
  return ws;
}

/** Minimal mock terminal with onData disposable and dispose method. */
function createMockTerminal() {
  const onDataDisposable = { dispose: vi.fn() };
  return {
    onData: vi.fn(() => onDataDisposable),
    onDataDisposable,
    dispose: vi.fn(),
    write: vi.fn(),
    clear: vi.fn(),
  };
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type SessionLike = Record<string, any>;

/** Drive a session through the happy path to the given state. */
function driveToState(id: string, target: 'connecting' | 'authenticating' | 'connected' | 'soft_disconnected' | 'reconnecting' | 'disconnected') {
  const order = ['connecting', 'authenticating', 'connected', 'soft_disconnected', 'reconnecting', 'disconnected'] as const;
  // For 'disconnected' via the direct connected->disconnected path
  if (target === 'disconnected') {
    transitionSession(id, 'connecting');
    transitionSession(id, 'authenticating');
    transitionSession(id, 'connected');
    transitionSession(id, 'disconnected');
    return;
  }
  for (const s of order) {
    transitionSession(id, s);
    if (s === target) break;
  }
}

/** Resolve the effect registration function from the state module. */
function getRegisterFn(): ((state: string, cb: (...args: unknown[]) => void) => void) | undefined {
  const fn = stateModule.registerTransitionEffect ?? stateModule.onTransition ?? stateModule.addTransitionEffect;
  return typeof fn === 'function' ? fn : undefined;
}

/** Resolve the state change subscription function from the state module. */
function getSubscribeFn(): ((cb: (...args: unknown[]) => void) => void) | undefined {
  const fn = stateModule.onStateChange ?? stateModule.subscribeStateChange ?? stateModule.addStateChangeListener;
  return typeof fn === 'function' ? fn : undefined;
}

// ---------- Tests ----------

describe('session state machine side-effects (#322)', () => {
  beforeEach(() => {
    appState.sessions.clear();
    appState.activeSessionId = null;
    vi.clearAllMocks();
    vi.useRealTimers();
  });

  // 1. Side-effect registration API

  describe('side-effect registration API', () => {
    it('registerTransitionEffect exists and is a function', () => {
      const fn = getRegisterFn();
      expect(typeof fn).toBe('function');
    });

    it('effects fire when entering a state', () => {
      const spy = vi.fn();
      createSession('fx-fire');

      const register = getRegisterFn();
      expect(register).toBeDefined();
      register!('connecting', spy);

      transitionSession('fx-fire', 'connecting');
      expect(spy).toHaveBeenCalled();
    });

    it('effects receive the session object and previous state', () => {
      const spy = vi.fn();
      createSession('fx-args');

      const register = getRegisterFn();
      expect(register).toBeDefined();
      register!('connecting', spy);

      transitionSession('fx-args', 'connecting');
      // Effect should be called with (session, previousState)
      expect(spy).toHaveBeenCalledWith(
        expect.objectContaining({ id: 'fx-args' }),
        'idle',
      );
    });
  });

  // 2. Entering 'connecting' state

  describe('entering connecting state', () => {
    it('should null previous WS handlers before new connection', () => {
      const session = createSession('ws-null') as SessionLike;
      const oldWs = createMockWebSocket();
      oldWs.onmessage = () => {};
      oldWs.onerror = () => {};
      oldWs.onclose = () => {};
      oldWs.onopen = () => {};
      session.ws = oldWs;

      transitionSession('ws-null', 'connecting');

      expect(oldWs.onmessage).toBeNull();
      expect(oldWs.onerror).toBeNull();
      expect(oldWs.onclose).toBeNull();
      expect(oldWs.onopen).toBeNull();
    });
  });

  // 3. Entering 'connected' state

  describe('entering connected state', () => {
    it('should clear reconnect timers', () => {
      vi.useFakeTimers();
      const session = createSession('clr-timer') as SessionLike;
      session.reconnectTimer = setTimeout(() => {}, 5000);

      driveToState('clr-timer', 'connected');

      expect(session.reconnectTimer).toBeNull();
    });

    it('should reset reconnect delay to initial value', () => {
      const session = createSession('rst-delay') as SessionLike;
      session.reconnectDelay = 16000; // escalated from backoff

      driveToState('rst-delay', 'connected');

      // RECONNECT.INITIAL_DELAY_MS is 2000
      expect(session.reconnectDelay).toBe(2000);
    });
  });

  // 4. Entering 'disconnected' state

  describe('entering disconnected state', () => {
    it('should null all WebSocket event handlers', () => {
      const session = createSession('dc-handlers') as SessionLike;
      const ws = createMockWebSocket();
      ws.onmessage = () => {};
      ws.onerror = () => {};
      ws.onclose = () => {};
      ws.onopen = () => {};
      session.ws = ws;

      driveToState('dc-handlers', 'disconnected');

      expect(ws.onmessage).toBeNull();
      expect(ws.onerror).toBeNull();
      expect(ws.onclose).toBeNull();
      expect(ws.onopen).toBeNull();
    });

    it('should close the WebSocket if still open', () => {
      const session = createSession('dc-close') as SessionLike;
      const ws = createMockWebSocket();
      session.ws = ws;

      driveToState('dc-close', 'disconnected');

      expect(ws.close).toHaveBeenCalled();
    });

    it('should set ws to null on the session', () => {
      const session = createSession('dc-null') as SessionLike;
      session.ws = createMockWebSocket();

      driveToState('dc-null', 'disconnected');

      expect(session.ws).toBeNull();
    });

    it('should stop keepalive timers', () => {
      vi.useFakeTimers();
      const session = createSession('dc-ka') as SessionLike;
      session.keepAliveTimer = setInterval(() => {}, 30000);

      driveToState('dc-ka', 'disconnected');

      expect(session.keepAliveTimer).toBeNull();
    });
  });

  // 5. Entering 'reconnecting' state

  describe('entering reconnecting state', () => {
    it('should fully clean up old WebSocket (handlers nulled, closed)', () => {
      const session = createSession('rc-ws') as SessionLike;
      const ws = createMockWebSocket();
      ws.onmessage = () => {};
      ws.onerror = () => {};
      ws.onclose = () => {};
      ws.onopen = () => {};
      session.ws = ws;

      // Drive to soft_disconnected then reconnecting
      transitionSession('rc-ws', 'connecting');
      transitionSession('rc-ws', 'authenticating');
      transitionSession('rc-ws', 'connected');
      transitionSession('rc-ws', 'soft_disconnected');
      transitionSession('rc-ws', 'reconnecting');

      expect(ws.onmessage).toBeNull();
      expect(ws.onerror).toBeNull();
      expect(ws.onclose).toBeNull();
      expect(ws.onopen).toBeNull();
      expect(ws.close).toHaveBeenCalled();
    });

    it('should dispose terminal.onData listener to prevent duplicate input handlers', () => {
      const session = createSession('rc-ondata') as SessionLike;
      const term = createMockTerminal();
      // Simulate that a terminal.onData listener was registered and tracked
      session._onDataDisposable = term.onDataDisposable;
      session.terminal = term;

      transitionSession('rc-ondata', 'connecting');
      transitionSession('rc-ondata', 'authenticating');
      transitionSession('rc-ondata', 'connected');
      transitionSession('rc-ondata', 'soft_disconnected');
      transitionSession('rc-ondata', 'reconnecting');

      // The onData disposable should have been called
      expect(term.onDataDisposable.dispose).toHaveBeenCalled();
    });

    it('should NOT destroy the terminal instance (output history preserved)', () => {
      const session = createSession('rc-term') as SessionLike;
      const term = createMockTerminal();
      session.terminal = term;

      transitionSession('rc-term', 'connecting');
      transitionSession('rc-term', 'authenticating');
      transitionSession('rc-term', 'connected');
      transitionSession('rc-term', 'soft_disconnected');
      transitionSession('rc-term', 'reconnecting');

      // Terminal should still be assigned (not disposed, not nulled)
      expect(session.terminal).not.toBeNull();
      expect(term.dispose).not.toHaveBeenCalled();
    });
  });

  // 6. Entering 'closed' state

  describe('entering closed state', () => {
    it('should close WebSocket and null handlers (same as disconnected)', () => {
      const session = createSession('cl-ws') as SessionLike;
      const ws = createMockWebSocket();
      ws.onmessage = () => {};
      ws.onerror = () => {};
      session.ws = ws;

      transitionSession('cl-ws', 'closed');

      expect(ws.close).toHaveBeenCalled();
      expect(ws.onmessage).toBeNull();
      expect(ws.onerror).toBeNull();
    });

    it('should dispose terminal instance', () => {
      const session = createSession('cl-term') as SessionLike;
      const term = createMockTerminal();
      session.terminal = term;

      transitionSession('cl-term', 'closed');

      expect(term.dispose).toHaveBeenCalled();
    });

    it('should clear reconnect timer', () => {
      vi.useFakeTimers();
      const session = createSession('cl-rtimer') as SessionLike;
      session.reconnectTimer = setTimeout(() => {}, 5000);

      transitionSession('cl-rtimer', 'closed');

      expect(session.reconnectTimer).toBeNull();
    });

    it('should clear keepalive timer', () => {
      vi.useFakeTimers();
      const session = createSession('cl-katimer') as SessionLike;
      session.keepAliveTimer = setInterval(() => {}, 30000);

      transitionSession('cl-katimer', 'closed');

      expect(session.keepAliveTimer).toBeNull();
    });

    it('should remove session from sessions map', () => {
      createSession('cl-map');
      expect(appState.sessions.has('cl-map')).toBe(true);

      transitionSession('cl-map', 'closed');

      expect(appState.sessions.has('cl-map')).toBe(false);
    });
  });

  // 7. Transition-triggered cleanup prevents listener leaks

  describe('listener leak prevention across full lifecycle', () => {
    it('connect -> disconnect -> reconnect -> connect: only ONE onmessage handler active', () => {
      const session = createSession('leak-msg') as SessionLike;

      // First connection
      const ws1 = createMockWebSocket();
      ws1.onmessage = () => {};
      session.ws = ws1;

      transitionSession('leak-msg', 'connecting');
      transitionSession('leak-msg', 'authenticating');
      transitionSession('leak-msg', 'connected');

      // Disconnect
      transitionSession('leak-msg', 'soft_disconnected');
      transitionSession('leak-msg', 'reconnecting');

      // Old WS should be cleaned up
      expect(ws1.onmessage).toBeNull();
      expect(ws1.close).toHaveBeenCalled();

      // Second connection
      const ws2 = createMockWebSocket();
      const handler2 = () => {};
      ws2.onmessage = handler2;
      session.ws = ws2;

      transitionSession('leak-msg', 'connected');

      // Only ws2 should have a handler; ws1 was cleaned
      expect(ws1.onmessage).toBeNull();
      expect(ws2.onmessage).toBe(handler2);
    });

    it('connect -> disconnect -> reconnect -> connect: only ONE terminal.onData active', () => {
      const session = createSession('leak-ondata') as SessionLike;
      const term = createMockTerminal();
      session.terminal = term;

      // First connection cycle
      const disposable1 = { dispose: vi.fn() };
      session._onDataDisposable = disposable1;

      transitionSession('leak-ondata', 'connecting');
      transitionSession('leak-ondata', 'authenticating');
      transitionSession('leak-ondata', 'connected');

      // Soft disconnect and reconnect
      transitionSession('leak-ondata', 'soft_disconnected');
      transitionSession('leak-ondata', 'reconnecting');

      // First disposable should have been disposed
      expect(disposable1.dispose).toHaveBeenCalled();

      // Second connection - new onData registered
      const disposable2 = { dispose: vi.fn() };
      session._onDataDisposable = disposable2;

      transitionSession('leak-ondata', 'connected');

      // Only the second disposable should be active (not disposed)
      expect(disposable2.dispose).not.toHaveBeenCalled();
      // First was already disposed
      expect(disposable1.dispose).toHaveBeenCalledTimes(1);
    });
  });

  // 8. UI notification on state change

  describe('UI notification on state change', () => {
    it('state transitions call a notification callback', () => {
      const subscribe = getSubscribeFn();
      expect(typeof subscribe).toBe('function');

      const spy = vi.fn();
      subscribe!(spy);

      createSession('ui-notify');
      transitionSession('ui-notify', 'connecting');

      expect(spy).toHaveBeenCalledWith(
        expect.objectContaining({ id: 'ui-notify' }),
        'connecting',
        'idle',
      );
    });

    it('UI subscriber receives every transition in a sequence', () => {
      const subscribe = getSubscribeFn();
      expect(subscribe).toBeDefined();

      const spy = vi.fn();
      subscribe!(spy);

      createSession('ui-seq');
      transitionSession('ui-seq', 'connecting');
      transitionSession('ui-seq', 'authenticating');
      transitionSession('ui-seq', 'connected');

      expect(spy).toHaveBeenCalledTimes(3);
      expect(spy).toHaveBeenNthCalledWith(1, expect.anything(), 'connecting', 'idle');
      expect(spy).toHaveBeenNthCalledWith(2, expect.anything(), 'authenticating', 'connecting');
      expect(spy).toHaveBeenNthCalledWith(3, expect.anything(), 'connected', 'authenticating');
    });
  });
});
