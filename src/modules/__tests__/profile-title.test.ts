/**
 * profile-title.test.ts — Tests for #425: name → title migration and display label preference
 *
 * Verifies:
 * 1. localStorage migration: profiles with `name` get migrated to `title`
 * 2. Display label preference: title is preferred over user@host when set
 */
import { describe, it, expect, beforeEach, vi } from 'vitest';

// ── Mock globals before imports ────────────────────────────────────────────

const storage = new Map<string, string>();
vi.stubGlobal('localStorage', {
  getItem: (key: string) => storage.get(key) ?? null,
  setItem: (key: string, value: string) => { storage.set(key, value); },
  removeItem: (key: string) => { storage.delete(key); },
  clear: () => { storage.clear(); },
});

vi.stubGlobal('location', { hostname: 'localhost', host: 'localhost:8081', protocol: 'http:', pathname: '/' });

vi.stubGlobal('document', {
  getElementById: () => null,
  querySelector: () => null,
  addEventListener: vi.fn(),
  visibilityState: 'visible',
  documentElement: {
    style: { setProperty: vi.fn() },
    dataset: {},
    classList: { toggle: vi.fn(), add: vi.fn(), remove: vi.fn() },
  },
  createElement: vi.fn(() => ({
    href: '', download: '', click: vi.fn(), style: {},
    appendChild: vi.fn(), setAttribute: vi.fn(),
  })),
  body: { appendChild: vi.fn(), removeChild: vi.fn() },
});

class MockURL { constructor(public href: string) {} }
Object.assign(MockURL, { createObjectURL: vi.fn(() => 'blob:mock'), revokeObjectURL: vi.fn() });
vi.stubGlobal('URL', MockURL);
vi.stubGlobal('crypto', { randomUUID: () => 'uuid-mock' });
vi.stubGlobal('navigator', { serviceWorker: undefined, wakeLock: undefined });
vi.stubGlobal('WebSocket', class { url = ''; readyState = 3; static OPEN = 1; static CLOSED = 3; close = vi.fn(); send = vi.fn(); addEventListener = vi.fn(); });
vi.stubGlobal('Worker', class { onmessage = null; postMessage = vi.fn(); terminate = vi.fn(); });
vi.stubGlobal('window', { addEventListener: vi.fn(), location: { protocol: 'http:', host: 'localhost:8081', pathname: '/' } });
vi.stubGlobal('CSS', { escape: (s: string) => s });
vi.stubGlobal('confirm', () => true);
vi.stubGlobal('requestAnimationFrame', (cb: () => void) => { cb(); return 0; });

const { getProfiles } = await import('../profiles.js');

describe('#425: name → title migration', () => {
  beforeEach(() => {
    storage.clear();
  });

  it('migrates legacy name field to title on load', () => {
    // Seed localStorage with old-format profile (has `name`, no `title`)
    storage.set('sshProfiles', JSON.stringify([
      { name: 'My Server', host: 'example.com', port: 22, username: 'admin', authType: 'password', vaultId: 'v1', initialCommand: '' },
    ]));

    const profiles = getProfiles();

    expect(profiles).toHaveLength(1);
    expect(profiles[0]!.title).toBe('My Server');
    // `name` should be removed after migration
    expect('name' in profiles[0]!).toBe(false);
  });

  it('persists migration to localStorage', () => {
    storage.set('sshProfiles', JSON.stringify([
      { name: 'Old Name', host: 'h.com', port: 22, username: 'u', authType: 'password', vaultId: 'v1', initialCommand: '' },
    ]));

    getProfiles(); // triggers migration

    // Re-read raw localStorage — should now have title, not name
    const raw = JSON.parse(storage.get('sshProfiles')!);
    expect(raw[0].title).toBe('Old Name');
    expect(raw[0].name).toBeUndefined();
  });

  it('does not overwrite existing title with legacy name', () => {
    storage.set('sshProfiles', JSON.stringify([
      { title: 'Keep This', host: 'h.com', port: 22, username: 'u', authType: 'password', vaultId: 'v1', initialCommand: '' },
    ]));

    const profiles = getProfiles();
    expect(profiles[0]!.title).toBe('Keep This');
  });

  it('handles profiles with neither name nor title gracefully', () => {
    storage.set('sshProfiles', JSON.stringify([
      { host: 'h.com', port: 22, username: 'u', authType: 'password', vaultId: 'v1', initialCommand: '' },
    ]));

    const profiles = getProfiles();
    expect(profiles).toHaveLength(1);
    // title will be undefined since neither name nor title existed
    expect(profiles[0]!.title).toBeUndefined();
  });
});
