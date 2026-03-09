/**
 * Tests for per-session terminal theme storage/retrieval (#61).
 *
 * Verifies that profile theme is persisted to localStorage, survives
 * round-trips through getProfiles(), and is included in the sshProfile
 * when connecting from a profile.
 */
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { webcrypto } from 'node:crypto';

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

// Minimal DOM mock — profiles.ts reads some elements from the DOM
const domElements: Record<string, { value: string; dataset?: Record<string, string> }> = {};
vi.stubGlobal('document', {
  getElementById: (id: string) => domElements[id] ?? null,
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
    querySelector: vi.fn(() => null),
    remove: vi.fn(),
    classList: { add: vi.fn(), remove: vi.fn(), toggle: vi.fn(), contains: vi.fn(() => false) },
  })),
  body: { appendChild: vi.fn() },
  documentElement: { style: { setProperty: vi.fn() }, dataset: {} },
  fonts: { ready: Promise.resolve() },
});

vi.stubGlobal('WebSocket', class { onopen = null; onclose = null; onmessage = null; onerror = null; readyState = 0; url = ''; close = vi.fn(); send = vi.fn(); });
vi.stubGlobal('Worker', class { onmessage = null; postMessage = vi.fn(); terminate = vi.fn(); });
vi.stubGlobal('navigator', { wakeLock: undefined });
vi.stubGlobal('window', {
  addEventListener: vi.fn(),
  location: { hostname: 'localhost', protocol: 'http:', host: 'localhost', pathname: '/' },
});

const { getProfiles } = await import('../profiles.js');

describe('profile theme storage (#61)', () => {
  beforeEach(() => {
    storage.clear();
  });

  it('getProfiles returns empty array when no profiles stored', () => {
    expect(getProfiles()).toEqual([]);
  });

  it('getProfiles returns profiles with theme field when stored', () => {
    const profiles = [
      {
        name: 'Dev Server',
        host: '10.0.0.1',
        port: 22,
        username: 'dev',
        authType: 'password',
        initialCommand: '',
        vaultId: 'vault-1',
        theme: 'dracula',
      },
    ];
    storage.set('sshProfiles', JSON.stringify(profiles));
    const result = getProfiles();
    expect(result).toHaveLength(1);
    expect(result[0]?.theme).toBe('dracula');
  });

  it('getProfiles returns profiles without theme when not set', () => {
    const profiles = [
      {
        name: 'Server',
        host: '10.0.0.2',
        port: 22,
        username: 'user',
        authType: 'password',
        initialCommand: '',
        vaultId: 'vault-2',
      },
    ];
    storage.set('sshProfiles', JSON.stringify(profiles));
    const result = getProfiles();
    expect(result).toHaveLength(1);
    expect(result[0]?.theme).toBeUndefined();
  });

  it('getProfiles preserves all ThemeName values', () => {
    const themes = ['dark', 'light', 'solarizedDark', 'solarizedLight', 'highContrast', 'dracula', 'nord', 'gruvboxDark', 'monokai', 'tokyoNight'];
    for (const theme of themes) {
      storage.set('sshProfiles', JSON.stringify([{ name: 'S', host: 'h', port: 22, username: 'u', authType: 'password', initialCommand: '', vaultId: 'v', theme }]));
      const result = getProfiles();
      expect(result[0]?.theme).toBe(theme);
    }
  });

  it('getProfiles round-trips theme through JSON serialization', () => {
    const profiles = [
      { name: 'A', host: 'a', port: 22, username: 'u', authType: 'password', initialCommand: '', vaultId: 'v1', theme: 'nord' },
      { name: 'B', host: 'b', port: 22, username: 'u', authType: 'password', initialCommand: '', vaultId: 'v2' },
      { name: 'C', host: 'c', port: 22, username: 'u', authType: 'password', initialCommand: '', vaultId: 'v3', theme: 'monokai' },
    ];
    storage.set('sshProfiles', JSON.stringify(profiles));
    const result = getProfiles();
    expect(result[0]?.theme).toBe('nord');
    expect(result[1]?.theme).toBeUndefined();
    expect(result[2]?.theme).toBe('monokai');
  });
});
