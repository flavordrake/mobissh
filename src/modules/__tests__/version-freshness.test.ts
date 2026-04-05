import { describe, it, expect, beforeEach, vi } from 'vitest';

// Stub browser globals BEFORE module imports

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

let _metaContent = '1.0.0:abc123';
vi.stubGlobal('document', {
  getElementById: () => null,
  querySelector: (sel: string) => {
    if (sel === 'meta[name="app-version"]') return { content: _metaContent };
    return null;
  },
  addEventListener: vi.fn(),
  visibilityState: 'visible',
  hasFocus: () => true,
  documentElement: { style: { setProperty: vi.fn() }, dataset: {} },
  createElement: vi.fn(() => ({
    className: '', textContent: '', innerHTML: '',
    appendChild: vi.fn(), addEventListener: vi.fn(), querySelector: vi.fn(),
  })),
});

const _dispatchedEvents: CustomEvent[] = [];
vi.stubGlobal('window', {
  addEventListener: vi.fn(),
  dispatchEvent: (e: CustomEvent) => { _dispatchedEvents.push(e); },
});

// Mock Notification
vi.stubGlobal('Notification', { permission: 'granted' });

// Mock navigator.serviceWorker
vi.stubGlobal('navigator', {
  serviceWorker: {
    register: vi.fn(() => Promise.resolve({ update: vi.fn() })),
    addEventListener: vi.fn(),
    ready: Promise.resolve({ showNotification: vi.fn() }),
    getRegistrations: vi.fn(() => Promise.resolve([])),
  },
  clipboard: { writeText: vi.fn() },
});

// Mock EventSource — captures listeners so we can simulate server messages
type ESListener = (e: { data: string }) => void;
const _esListeners = new Map<string, ESListener>();

class MockEventSource {
  constructor(public url: string) {}
  addEventListener(event: string, fn: ESListener): void {
    _esListeners.set(event, fn);
  }
  close(): void {}
}

vi.stubGlobal('EventSource', MockEventSource);

const { connectSSE } = await import('../settings.js');

/** Simulate a server SSE version event. */
function simulateVersionEvent(data: { version: string; hash: string; uptime: number }): void {
  const listener = _esListeners.get('version');
  if (listener) listener({ data: JSON.stringify(data) });
}

describe('connectSSE', () => {
  beforeEach(() => {
    _esListeners.clear();
    _dispatchedEvents.length = 0;
    _metaContent = '1.0.0:abc123';
  });

  it('creates EventSource pointing to events endpoint', () => {
    connectSSE();
    // EventSource is a class mock — verify listener was registered for 'version'
    expect(_esListeners.has('version')).toBe(true);
  });

  it('logs fresh when server hash matches local hash', () => {
    const logSpy = vi.spyOn(console, 'log');
    connectSSE();
    simulateVersionEvent({ version: '1.0.0', hash: 'abc123', uptime: 10 });

    expect(logSpy).toHaveBeenCalledWith(expect.stringContaining('[sse] fresh'));
    expect(_dispatchedEvents).toHaveLength(0);
    logSpy.mockRestore();
  });

  it('warns and dispatches version-stale when hashes differ', () => {
    const warnSpy = vi.spyOn(console, 'warn');
    connectSSE();
    simulateVersionEvent({ version: '1.1.0', hash: 'def456', uptime: 5 });

    expect(warnSpy).toHaveBeenCalledWith(expect.stringContaining('[sse] STALE'));
    expect(_dispatchedEvents).toHaveLength(1);
    expect(_dispatchedEvents[0]!.type).toBe('version-stale');

    const detail = _dispatchedEvents[0]!.detail as { local: { hash: string }; server: { hash: string } };
    expect(detail.local.hash).toBe('abc123');
    expect(detail.server.hash).toBe('def456');
    warnSpy.mockRestore();
  });

  it('logs server version and uptime on every version event', () => {
    const logSpy = vi.spyOn(console, 'log');
    connectSSE();
    simulateVersionEvent({ version: '1.0.0', hash: 'abc123', uptime: 42 });

    expect(logSpy).toHaveBeenCalledWith(expect.stringContaining('uptime 42s'));
    logSpy.mockRestore();
  });

  it('handles missing meta tag gracefully', () => {
    _metaContent = '';
    const warnSpy = vi.spyOn(console, 'warn');
    connectSSE();

    expect(warnSpy).toHaveBeenCalledWith(expect.stringContaining('[sse] no app-version meta'));
    warnSpy.mockRestore();
  });
});
