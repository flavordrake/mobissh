import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { webcrypto } from 'node:crypto';

// Stub browser globals before any module imports
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

// Capture visibilitychange handler
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

// Track WebSocket instances
let lastWsInstance: {
  onopen: ((e?: unknown) => void) | null;
  onclose: ((e?: unknown) => void) | null;
  onmessage: ((e?: unknown) => void) | null;
  onerror: ((e?: unknown) => void) | null;
  readyState: number;
  url: string;
  close: ReturnType<typeof vi.fn>;
  send: ReturnType<typeof vi.fn>;
} | null = null;

vi.stubGlobal('WebSocket', class {
  onopen: ((e?: unknown) => void) | null = null;
  onclose: ((e?: unknown) => void) | null = null;
  onmessage: ((e?: unknown) => void) | null = null;
  onerror: ((e?: unknown) => void) | null = null;
  readyState = 1;
  url: string;
  close = vi.fn();
  send = vi.fn();
  private _listeners: Record<string, Array<(...args: unknown[]) => void>> = {};
  addEventListener = vi.fn((event: string, handler: (...args: unknown[]) => void) => {
    if (!this._listeners[event]) this._listeners[event] = [];
    this._listeners[event]!.push(handler);
  });
  removeEventListener = vi.fn((event: string, handler: (...args: unknown[]) => void) => {
    const list = this._listeners[event];
    if (list) this._listeners[event] = list.filter(h => h !== handler);
  });
  static OPEN = 1;
  static CLOSED = 3;
  static CLOSING = 2;
  constructor(url: string) {
    this.url = url;
    // eslint-disable-next-line @typescript-eslint/no-this-alias
    lastWsInstance = this;
  }
});
vi.stubGlobal('Worker', class { onmessage = null; postMessage = vi.fn(); terminate = vi.fn(); });
vi.stubGlobal('navigator', { wakeLock: undefined });
vi.stubGlobal('window', {
  addEventListener: vi.fn(),
  location: { protocol: 'http:', host: 'localhost:8081', pathname: '/' },
});

vi.useFakeTimers();

const { cancelReconnect, scheduleReconnect, _probeZombieConnection } = await import('../connection.js');
const { appState, createSession, transitionSession } = await import('../state.js');

/** Helper: create a session with profile and optional WS */
function _setupSession(opts?: { ws?: unknown; profile?: boolean; connected?: boolean }): void {
  const profile = { title: 'test', host: 'test', port: 22, username: 'test', authType: 'password' as const };
  const session = createSession('test-session');
  appState.activeSessionId = 'test-session';
  if (opts?.profile !== false) session.profile = profile;
  if (opts?.ws !== undefined) session.ws = opts.ws as WebSocket;
  if (opts?.connected) {
    transitionSession('test-session', 'connecting');
    transitionSession('test-session', 'authenticating');
    transitionSession('test-session', 'connected');
  }
}

describe('visibility-triggered reconnect (#153)', () => {
  beforeEach(() => {
    vi.runAllTimers();
    storage.clear();
    appState.sessions.clear();
    appState.activeSessionId = null;
    appState.hasConnected = false;
    _visibilityState = 'visible';
    lastWsInstance = null;
    mockErrorOverlay.classList.add.mockClear();
  });

  afterEach(() => {
    cancelReconnect();
  });

  it('reconnects immediately when WS is closed on resume', () => {
    // Simulate having a profile and a dead WS
    _setupSession({ ws: null });

    // Go hidden then visible
    _visibilityState = 'hidden';
    visibilityHandler?.();
    _visibilityState = 'visible';
    visibilityHandler?.();

    // Should have created a new WebSocket (reconnect attempt)
    expect(lastWsInstance).not.toBeNull();
  });

  it('does not reconnect when no profile is set', () => {
    // No session at all — no profile
    _visibilityState = 'visible';
    visibilityHandler?.();

    expect(lastWsInstance).toBeNull();
  });

  it('probes zombie connection when WS appears open on resume', () => {
    // Set up an apparently-open WS
    const fakeWs = {
      readyState: 1, // OPEN
      url: 'ws://localhost:8081',
      send: vi.fn(),
      close: vi.fn(),
      onopen: null,
      onclose: null,
      onmessage: null,
      onerror: null,
    };
    _setupSession({ ws: fakeWs, connected: true });

    // Resume from background
    _visibilityState = 'visible';
    visibilityHandler?.();

    // Should have sent a ping probe
    expect(fakeWs.send).toHaveBeenCalledWith(JSON.stringify({ type: 'ping' }));
  });

  it('force-closes zombie WS after probe timeout', () => {
    const fakeWs = {
      readyState: 1,
      url: 'ws://localhost:8081',
      send: vi.fn(),
      close: vi.fn(),
      onopen: null,
      onclose: null as ((e?: unknown) => void) | null,
      onmessage: null as ((e?: unknown) => void) | null,
      onerror: null,
    };
    _setupSession({ ws: fakeWs, connected: true });

    // Resume — starts probe
    _visibilityState = 'visible';
    visibilityHandler?.();

    // Advance past the probe timeout (5 seconds)
    vi.advanceTimersByTime(5000);

    // WS should have been force-closed
    expect(fakeWs.close).toHaveBeenCalled();
  });

  it('cancels probe when WS message arrives (connection alive)', () => {
    const fakeWs = {
      readyState: 1,
      url: 'ws://localhost:8081',
      send: vi.fn(),
      close: vi.fn(),
      onopen: null,
      onclose: null as ((e?: unknown) => void) | null,
      onmessage: null as ((e?: unknown) => void) | null,
      onerror: null,
    };
    _setupSession({ ws: fakeWs, connected: true });

    // Resume — starts probe
    _visibilityState = 'visible';
    visibilityHandler?.();

    // Simulate receiving a message (connection is alive)
    // The probe should wrap the existing onmessage to detect activity
    if (fakeWs.onmessage) {
      fakeWs.onmessage({ data: JSON.stringify({ type: 'output', data: 'x' }) });
    }

    // Advance past probe timeout — should NOT close
    vi.advanceTimersByTime(5000);
    expect(fakeWs.close).not.toHaveBeenCalled();
  });

  it('dismisses pending reconnect timer on resume', () => {
    _setupSession({ ws: null });

    // Schedule a reconnect with backoff
    scheduleReconnect();
    const session = appState.sessions.get('test-session')!;
    expect(session.reconnectTimer).not.toBeNull();

    // Resume
    _visibilityState = 'visible';
    visibilityHandler?.();

    // The pending timer should have been cancelled (cancelReconnect called)
    // and an immediate reconnect should have happened
    expect(lastWsInstance).not.toBeNull();
  });

  it('dismisses error dialog overlay on resume reconnect', () => {
    _setupSession({ ws: null });

    _visibilityState = 'visible';
    visibilityHandler?.();

    expect(mockErrorOverlay.classList.add).toHaveBeenCalledWith('hidden');
  });

  it('scheduleReconnect targets the passed sessionId, not activeSessionId', () => {
    // Regression: the SSH 'disconnected' message handler used to call
    // scheduleReconnect() with no argument, which defaulted to activeSessionId.
    // If session A disconnected while session B was foregrounded, B got
    // reconnect-thrashed instead of A. Lock the explicit-target path.
    const profileA = { title: 'A', host: 'host-a', port: 22, username: 'u', authType: 'password' as const };
    const profileB = { title: 'B', host: 'host-b', port: 22, username: 'u', authType: 'password' as const };
    const sA = createSession('sess-A');
    sA.profile = profileA;
    transitionSession('sess-A', 'connecting');
    transitionSession('sess-A', 'authenticating');
    transitionSession('sess-A', 'connected');
    transitionSession('sess-A', 'soft_disconnected');

    const sB = createSession('sess-B');
    sB.profile = profileB;
    transitionSession('sess-B', 'connecting');
    transitionSession('sess-B', 'authenticating');
    transitionSession('sess-B', 'connected');

    // User is looking at session B in the UI.
    appState.activeSessionId = 'sess-B';

    // SSH on session A disconnected — the WS handler now passes sessionId.
    scheduleReconnect('sess-A');

    expect(sA.reconnectTimer).not.toBeNull();
    expect(sB.reconnectTimer).toBeNull();
  });
});

describe('_probeZombieConnection (#153)', () => {
  beforeEach(() => {
    vi.runAllTimers();
    storage.clear();
    appState.sessions.clear();
    appState.activeSessionId = null;
    lastWsInstance = null;
  });

  it('is exported and callable', () => {
    expect(typeof _probeZombieConnection).toBe('function');
  });

  it('does nothing when WS is null', () => {
    // No session — should not throw
    expect(() => _probeZombieConnection()).not.toThrow();
  });

  it('does nothing when WS is not OPEN', () => {
    const fakeWs = {
      readyState: 3, // CLOSED
      send: vi.fn(),
      close: vi.fn(),
      onmessage: null,
    };
    _setupSession({ ws: fakeWs });
    _probeZombieConnection();
    expect(fakeWs.send).not.toHaveBeenCalled();
  });
});
