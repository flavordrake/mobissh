import { describe, it, expect, beforeEach, vi } from 'vitest';
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

// Minimal DOM mock (connection.ts registers document event listeners at module load)
vi.stubGlobal('document', {
  getElementById: () => null,
  querySelector: () => null,
  addEventListener: vi.fn(),
  visibilityState: 'visible',
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

vi.stubGlobal('WebSocket', class {
  onopen = null; onclose = null; onmessage = null; onerror = null;
  readyState = 1; // OPEN
  url = 'ws://localhost:8081';
  close = vi.fn(); send = vi.fn();
  static OPEN = 1;
});
vi.stubGlobal('navigator', { wakeLock: undefined });
vi.stubGlobal('window', { addEventListener: vi.fn() });

vi.useFakeTimers();

const { _startKeepAlive, _stopKeepAlive } = await import('../connection.js');
const { appState, createSession } = await import('../state.js');

describe('per-session keep-alive timer isolation (#62)', () => {
  beforeEach(() => {
    appState.sessions.clear();
    appState.activeSessionId = null;
  });

  it('startKeepAlive sets timer on the target session only', () => {
    const fakeWs = { readyState: 1, url: 'ws://localhost:8081', send: vi.fn(), close: vi.fn(), onopen: null, onclose: null, onmessage: null, onerror: null } as unknown as WebSocket;
    const s1 = createSession('session-1');
    s1.ws = fakeWs;
    const s2 = createSession('session-2');

    _startKeepAlive('session-1');

    expect(s1.keepAliveTimer).not.toBeNull();
    expect(s2.keepAliveTimer).toBeNull();
  });

  it('stopKeepAlive clears timer on the target session only', () => {
    const fakeWs = { readyState: 1, url: 'ws://localhost:8081', send: vi.fn(), close: vi.fn(), onopen: null, onclose: null, onmessage: null, onerror: null } as unknown as WebSocket;
    const s1 = createSession('session-a');
    s1.ws = fakeWs;
    const s2 = createSession('session-b');
    s2.ws = fakeWs;

    _startKeepAlive('session-a');
    _startKeepAlive('session-b');

    expect(s1.keepAliveTimer).not.toBeNull();
    expect(s2.keepAliveTimer).not.toBeNull();

    _stopKeepAlive('session-a');

    expect(s1.keepAliveTimer).toBeNull();
    // session-b timer must survive
    expect(s2.keepAliveTimer).not.toBeNull();
  });

  it('startKeepAlive does NOT spawn a Web Worker', () => {
    // The keepalive Worker spawn was removed (2026-04-29). It opened a
    // SECOND WS per session for ping-only traffic — doubled bridge load
    // without keeping the real SSH WS alive. Verify no worker is created.
    const workerSpawn = vi.fn();
    vi.stubGlobal('Worker', class {
      constructor() { workerSpawn(); }
      onmessage = null; postMessage = vi.fn(); terminate = vi.fn();
    });
    const fakeWs = { readyState: 1, url: 'ws://localhost:8081', send: vi.fn(), close: vi.fn(), onopen: null, onclose: null, onmessage: null, onerror: null } as unknown as WebSocket;
    const s = createSession('no-worker');
    s.ws = fakeWs;

    _startKeepAlive('no-worker');

    expect(workerSpawn).not.toHaveBeenCalled();
    expect(s.keepAliveTimer).not.toBeNull();
  });

  it('startKeepAlive is a no-op for unknown sessionId', () => {
    // Should not throw
    expect(() => _startKeepAlive('nonexistent')).not.toThrow();
  });

  it('stopKeepAlive is a no-op for unknown sessionId', () => {
    expect(() => _stopKeepAlive('nonexistent')).not.toThrow();
  });

  it('stopKeepAlive clears the timer', () => {
    const fakeWs = { readyState: 1, url: 'ws://localhost:8081', send: vi.fn(), close: vi.fn(), onopen: null, onclose: null, onmessage: null, onerror: null } as unknown as WebSocket;
    const s = createSession('full-stop');
    s.ws = fakeWs;
    _startKeepAlive('full-stop');
    expect(s.keepAliveTimer).not.toBeNull();

    _stopKeepAlive('full-stop');
    expect(s.keepAliveTimer).toBeNull();
  });
});
