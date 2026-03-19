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
const { appState, createSession } = await import('../state.js');
const { RECONNECT } = await import('../constants.js');

describe('visibility-triggered reconnect (#153)', () => {
  beforeEach(() => {
    storage.clear();
    appState.sessions.clear();
    appState.activeSessionId = null;
    appState.ws = null;
    appState._wsConnected = false;
    appState.sshConnected = false;
    appState.currentProfile = null;
    appState.reconnectTimer = null;
    appState.reconnectDelay = RECONNECT.INITIAL_DELAY_MS;
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
    appState.currentProfile = { name: 'test', host: 'test', port: 22, username: 'test', authType: 'password' as const };
    appState.ws = null; // WS already gone

    // Go hidden then visible
    _visibilityState = 'hidden';
    visibilityHandler?.();
    _visibilityState = 'visible';
    visibilityHandler?.();

    // Should have created a new WebSocket (reconnect attempt)
    expect(lastWsInstance).not.toBeNull();
  });

  it('does not reconnect when no profile is set', () => {
    appState.currentProfile = null;
    appState.ws = null;

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
    appState.ws = fakeWs as unknown as WebSocket;
    appState._wsConnected = true;
    appState.sshConnected = true;
    appState.currentProfile = { name: 'test', host: 'test', port: 22, username: 'test', authType: 'password' as const };
    const session = createSession('test-session');
    appState.activeSessionId = 'test-session';
    session.profile = appState.currentProfile;

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
    appState.ws = fakeWs as unknown as WebSocket;
    appState._wsConnected = true;
    appState.sshConnected = true;
    appState.currentProfile = { name: 'test', host: 'test', port: 22, username: 'test', authType: 'password' as const };
    const session = createSession('test-session');
    appState.activeSessionId = 'test-session';
    session.profile = appState.currentProfile;

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
    appState.ws = fakeWs as unknown as WebSocket;
    appState._wsConnected = true;
    appState.sshConnected = true;
    appState.currentProfile = { name: 'test', host: 'test', port: 22, username: 'test', authType: 'password' as const };
    const session = createSession('test-session');
    appState.activeSessionId = 'test-session';
    session.profile = appState.currentProfile;

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
    appState.currentProfile = { name: 'test', host: 'test', port: 22, username: 'test', authType: 'password' as const };
    appState.ws = null;

    // Schedule a reconnect with backoff
    scheduleReconnect();
    expect(appState.reconnectTimer).not.toBeNull();

    // Resume
    _visibilityState = 'visible';
    visibilityHandler?.();

    // The pending timer should have been cancelled (cancelReconnect called)
    // and an immediate reconnect should have happened
    expect(lastWsInstance).not.toBeNull();
  });

  it('dismisses error dialog overlay on resume reconnect', () => {
    appState.currentProfile = { name: 'test', host: 'test', port: 22, username: 'test', authType: 'password' as const };
    appState.ws = null;

    _visibilityState = 'visible';
    visibilityHandler?.();

    expect(mockErrorOverlay.classList.add).toHaveBeenCalledWith('hidden');
  });
});

describe('_probeZombieConnection (#153)', () => {
  beforeEach(() => {
    storage.clear();
    appState.ws = null;
    appState._wsConnected = false;
    appState.sshConnected = false;
    appState.currentProfile = null;
    lastWsInstance = null;
  });

  it('is exported and callable', () => {
    expect(typeof _probeZombieConnection).toBe('function');
  });

  it('does nothing when WS is null', () => {
    appState.ws = null;
    // Should not throw
    expect(() => _probeZombieConnection()).not.toThrow();
  });

  it('does nothing when WS is not OPEN', () => {
    const fakeWs = {
      readyState: 3, // CLOSED
      send: vi.fn(),
      close: vi.fn(),
      onmessage: null,
    };
    appState.ws = fakeWs as unknown as WebSocket;
    _probeZombieConnection();
    expect(fakeWs.send).not.toHaveBeenCalled();
  });
});
