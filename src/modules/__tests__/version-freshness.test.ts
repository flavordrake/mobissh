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

// Mock fetch
const _fetchMock = vi.fn();
vi.stubGlobal('fetch', _fetchMock);

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

const { checkVersionFreshness } = await import('../settings.js');

describe('checkVersionFreshness', () => {
  beforeEach(() => {
    _fetchMock.mockReset();
    _dispatchedEvents.length = 0;
    _metaContent = '1.0.0:abc123';
  });

  it('logs fresh when server hash matches local hash', async () => {
    const logSpy = vi.spyOn(console, 'log');
    _fetchMock.mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ version: '1.0.0', hash: 'abc123' }),
    });

    await checkVersionFreshness();

    expect(logSpy).toHaveBeenCalledWith(expect.stringContaining('[version] fresh'));
    expect(_dispatchedEvents).toHaveLength(0);
    logSpy.mockRestore();
  });

  it('warns and dispatches version-stale when hashes differ', async () => {
    const warnSpy = vi.spyOn(console, 'warn');
    _fetchMock.mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ version: '1.1.0', hash: 'def456' }),
    });

    await checkVersionFreshness();

    expect(warnSpy).toHaveBeenCalledWith(expect.stringContaining('[version] STALE'));
    expect(_dispatchedEvents).toHaveLength(1);
    expect(_dispatchedEvents[0]!.type).toBe('version-stale');

    const detail = _dispatchedEvents[0]!.detail as { local: { hash: string }; server: { hash: string } };
    expect(detail.local.hash).toBe('abc123');
    expect(detail.server.hash).toBe('def456');
    warnSpy.mockRestore();
  });

  it('handles network failure gracefully (offline)', async () => {
    const logSpy = vi.spyOn(console, 'log');
    _fetchMock.mockRejectedValue(new Error('network error'));

    await checkVersionFreshness();

    expect(logSpy).toHaveBeenCalledWith(expect.stringContaining('[version] offline'));
    expect(_dispatchedEvents).toHaveLength(0);
    logSpy.mockRestore();
  });

  it('handles non-200 response', async () => {
    const warnSpy = vi.spyOn(console, 'warn');
    _fetchMock.mockResolvedValue({ ok: false, status: 500 });

    await checkVersionFreshness();

    expect(warnSpy).toHaveBeenCalledWith(expect.stringContaining('/version returned 500'));
    expect(_dispatchedEvents).toHaveLength(0);
    warnSpy.mockRestore();
  });

  it('warns when app-version meta tag is missing', async () => {
    _metaContent = '';
    // querySelector returns { content: '' } which is falsy for ?.content check
    const warnSpy = vi.spyOn(console, 'warn');

    await checkVersionFreshness();

    expect(warnSpy).toHaveBeenCalledWith(expect.stringContaining('no app-version meta'));
    warnSpy.mockRestore();
  });
});
