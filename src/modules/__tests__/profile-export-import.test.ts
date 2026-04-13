/**
 * profile-export-import.test.ts — Tests for #419: export/import profiles
 *
 * Verifies:
 * 1. SECURITY: export excludes all sensitive fields
 * 2. Export includes only safe metadata fields
 * 3. Import validates and deduplicates profiles
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
vi.stubGlobal('Blob', class { constructor(public parts: string[], public options: { type: string }) {} });

const { getProfiles, exportProfilesJSON, importProfilesFromJSON } = await import('../profiles.js');

/** Seed localStorage with profiles that have sensitive fields. */
function seedProfiles(): void {
  storage.set('sshProfiles', JSON.stringify([
    {
      title: 'Dev Server',
      host: 'dev.example.com',
      port: 22,
      username: 'admin',
      authType: 'password',
      initialCommand: '',
      vaultId: 'vault-secret-123',
      hasVaultCreds: true,
      keyVaultId: 'key-vault-456',
      theme: 'dark',
    },
    {
      title: 'Prod Server',
      host: 'prod.example.com',
      port: 2222,
      username: 'deploy',
      authType: 'key',
      initialCommand: 'tmux attach',
      vaultId: 'vault-secret-789',
      hasVaultCreds: true,
      theme: 'nord',
    },
  ]));
}

describe('#419: export profiles — security boundary', () => {
  beforeEach(() => {
    storage.clear();
  });

  it('SECURITY: export does NOT include password, privateKey, passphrase, vaultId, keyVaultId, or hasVaultCreds', () => {
    seedProfiles();
    const json = exportProfilesJSON();
    const parsed = JSON.parse(json);

    const SENSITIVE_FIELDS = ['password', 'privateKey', 'passphrase', 'vaultId', 'keyVaultId', 'hasVaultCreds'];

    for (const profile of parsed) {
      for (const field of SENSITIVE_FIELDS) {
        expect(profile).not.toHaveProperty(field);
      }
    }
  });

  it('export includes only safe metadata: title, host, port, username, authType', () => {
    seedProfiles();
    const json = exportProfilesJSON();
    const parsed = JSON.parse(json);

    expect(parsed).toHaveLength(2);
    expect(parsed[0]).toEqual({
      title: 'Dev Server',
      host: 'dev.example.com',
      port: 22,
      username: 'admin',
      authType: 'password',
    });
    expect(parsed[1]).toEqual({
      title: 'Prod Server',
      host: 'prod.example.com',
      port: 2222,
      username: 'deploy',
      authType: 'key',
    });
  });

  it('export returns empty array JSON when no profiles exist', () => {
    const json = exportProfilesJSON();
    expect(JSON.parse(json)).toEqual([]);
  });
});

describe('#419: import profiles', () => {
  beforeEach(() => {
    storage.clear();
  });

  it('imports valid profiles into storage', () => {
    const input = JSON.stringify([
      { title: 'New Server', host: 'new.example.com', port: 22, username: 'user', authType: 'password' },
    ]);

    const result = importProfilesFromJSON(input);
    expect(result.added).toBe(1);
    expect(result.skipped).toBe(0);
    expect(result.errors).toHaveLength(0);

    const profiles = getProfiles();
    expect(profiles).toHaveLength(1);
    expect(profiles[0]!.title).toBe('New Server');
  });

  it('deduplicates by host+port+username — skips existing profiles', () => {
    // Seed an existing profile
    storage.set('sshProfiles', JSON.stringify([
      { title: 'Existing', host: 'dev.example.com', port: 22, username: 'admin', authType: 'password', vaultId: 'v1', initialCommand: '' },
    ]));

    const input = JSON.stringify([
      { title: 'Duplicate', host: 'dev.example.com', port: 22, username: 'admin', authType: 'password' },
      { title: 'New One', host: 'other.com', port: 22, username: 'root', authType: 'key' },
    ]);

    const result = importProfilesFromJSON(input);
    expect(result.added).toBe(1);
    expect(result.skipped).toBe(1);

    const profiles = getProfiles();
    expect(profiles).toHaveLength(2);
    // The existing profile keeps its original title
    expect(profiles[0]!.title).toBe('Existing');
    expect(profiles[1]!.title).toBe('New One');
  });

  it('rejects invalid JSON', () => {
    const result = importProfilesFromJSON('not json');
    expect(result.added).toBe(0);
    expect(result.errors).toHaveLength(1);
    expect(result.errors[0]).toMatch(/invalid/i);
  });

  it('rejects entries missing required fields', () => {
    const input = JSON.stringify([
      { title: 'No Host', port: 22, username: 'user', authType: 'password' },
      { title: 'Valid', host: 'ok.com', port: 22, username: 'user', authType: 'password' },
    ]);

    const result = importProfilesFromJSON(input);
    expect(result.added).toBe(1);
    expect(result.errors).toHaveLength(1);
    expect(result.errors[0]).toMatch(/host/i);
  });

  it('strips any sensitive fields from import data', () => {
    const input = JSON.stringify([
      {
        title: 'Sneaky', host: 'evil.com', port: 22, username: 'hacker', authType: 'password',
        password: 'secret', privateKey: 'PRIVATE', passphrase: 'pass', vaultId: 'steal-me',
      },
    ]);

    const result = importProfilesFromJSON(input);
    expect(result.added).toBe(1);

    const profiles = getProfiles();
    const imported = profiles[0]!;
    expect(imported).not.toHaveProperty('password');
    expect(imported).not.toHaveProperty('privateKey');
    expect(imported).not.toHaveProperty('passphrase');
    // vaultId is generated fresh, not taken from import
    expect(imported.vaultId).not.toBe('steal-me');
  });
});
