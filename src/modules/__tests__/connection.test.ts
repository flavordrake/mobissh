import { describe, it, expect, beforeEach, vi } from 'vitest';
import { webcrypto } from 'node:crypto';

// Stub browser globals before any module imports
vi.stubGlobal('crypto', webcrypto);

const storage = new Map<string, string>();
const localStorageMock = {
  getItem: (key: string) => storage.get(key) ?? null,
  setItem: (key: string, value: string) => { storage.set(key, value); },
  removeItem: (key: string) => { storage.delete(key); },
  clear: () => { storage.clear(); },
  get length() { return storage.size; },
  key: (_i: number) => null as string | null,
};
vi.stubGlobal('localStorage', localStorageMock);
vi.stubGlobal('location', { hostname: 'localhost' });

// Mock DOM elements for passphrase prompt
const mockOverlay = {
  classList: { remove: vi.fn(), add: vi.fn() },
  id: 'keyPassphraseOverlay',
};
const mockInput = { value: '', focus: vi.fn(), addEventListener: vi.fn(), removeEventListener: vi.fn() };
const mockOkBtn = { addEventListener: vi.fn(), removeEventListener: vi.fn() };
const mockCancelBtn = { addEventListener: vi.fn(), removeEventListener: vi.fn() };
const mockErrorEl = { classList: { add: vi.fn() } };

vi.stubGlobal('document', {
  getElementById: (id: string) => {
    switch (id) {
      case 'keyPassphraseOverlay': return mockOverlay;
      case 'keyPassphraseInput': return mockInput;
      case 'keyPassphraseOk': return mockOkBtn;
      case 'keyPassphraseCancel': return mockCancelBtn;
      case 'keyPassphraseError': return mockErrorEl;
      default: return null;
    }
  },
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

vi.stubGlobal('WebSocket', class { onopen = null; onclose = null; onmessage = null; onerror = null; readyState = 0; url = ''; close = vi.fn(); send = vi.fn(); });
vi.stubGlobal('Worker', class { onmessage = null; postMessage = vi.fn(); terminate = vi.fn(); });
vi.stubGlobal('navigator', { wakeLock: undefined });

// Mock beforeunload listener registration
const beforeUnloadHandlers: (() => void)[] = [];
vi.stubGlobal('window', {
  addEventListener: (event: string, handler: () => void) => {
    if (event === 'beforeunload') beforeUnloadHandlers.push(handler);
  },
});

const { _getPassphraseCache } = await import('../connection.js');

describe('Key passphrase cache (#54)', () => {
  beforeEach(() => {
    _getPassphraseCache().clear();
  });

  it('cache starts empty', () => {
    expect(_getPassphraseCache().size).toBe(0);
  });

  it('stores and retrieves cached passphrases', () => {
    const cache = _getPassphraseCache();
    cache.set('key-vault-id-1', 'my-passphrase');
    expect(cache.get('key-vault-id-1')).toBe('my-passphrase');
  });

  it('beforeunload clears the cache', () => {
    const cache = _getPassphraseCache();
    cache.set('key-vault-id-1', 'my-passphrase');
    expect(cache.size).toBe(1);

    // Fire beforeunload handlers
    for (const handler of beforeUnloadHandlers) handler();

    expect(cache.size).toBe(0);
  });

  it('caches different passphrases for different keys', () => {
    const cache = _getPassphraseCache();
    cache.set('key-1', 'pass-1');
    cache.set('key-2', 'pass-2');
    expect(cache.get('key-1')).toBe('pass-1');
    expect(cache.get('key-2')).toBe('pass-2');
  });
});
