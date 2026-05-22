/**
 * profile-export-native.test.ts — Tests for #501: PWA→native profile export.
 *
 * Verifies the new versioned-wrapper shape consumed by the Flutter native
 * client's `ProfilesStore.importFromJson`:
 *   { version: 1, exportedAt: <ISO-8601>, profiles: [...] }
 *
 * Security boundary: NO credentials, NO vaultId/keyVaultId/hasVaultCreds.
 * Round-trip: parsing the envelope yields the same profile metadata in.
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

const clipboardWrites: string[] = [];
const downloads: { href: string; download: string }[] = [];

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
  createElement: vi.fn(() => {
    const a: { href: string; download: string; click: () => void; style: Record<string, string> } = {
      href: '', download: '', click() { downloads.push({ href: this.href, download: this.download }); }, style: {},
    };
    return a;
  }),
  body: { appendChild: vi.fn(), removeChild: vi.fn() },
});

class MockURL { constructor(public href: string) {} }
Object.assign(MockURL, { createObjectURL: vi.fn(() => 'blob:mock'), revokeObjectURL: vi.fn() });
vi.stubGlobal('URL', MockURL);
vi.stubGlobal('crypto', { randomUUID: () => 'uuid-mock' });
vi.stubGlobal('navigator', {
  serviceWorker: undefined,
  wakeLock: undefined,
  clipboard: {
    writeText: vi.fn((s: string) => {
      clipboardWrites.push(s);
      return Promise.resolve();
    }),
  },
});
vi.stubGlobal('WebSocket', class { url = ''; readyState = 3; static OPEN = 1; static CLOSED = 3; close = vi.fn(); send = vi.fn(); addEventListener = vi.fn(); });
vi.stubGlobal('Worker', class { onmessage = null; postMessage = vi.fn(); terminate = vi.fn(); });
vi.stubGlobal('window', { addEventListener: vi.fn(), location: { protocol: 'http:', host: 'localhost:8081', pathname: '/' } });
vi.stubGlobal('CSS', { escape: (s: string) => s });
vi.stubGlobal('confirm', () => true);
vi.stubGlobal('requestAnimationFrame', (cb: () => void) => { cb(); return 0; });
vi.stubGlobal('Blob', class { constructor(public parts: string[], public options: { type: string }) {} });

const { exportProfilesJson, triggerProfilesDownload } = await import('../profiles.js');

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
      color: '#ff8800',
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

describe('#501: exportProfilesJson — versioned wrapper', () => {
  beforeEach(() => {
    storage.clear();
    clipboardWrites.length = 0;
    downloads.length = 0;
  });

  it('emits a wrapper object with version=1, ISO-8601 exportedAt, profiles array', () => {
    seedProfiles();
    const json = exportProfilesJson();
    const parsed = JSON.parse(json);

    expect(parsed.version).toBe(1);
    expect(typeof parsed.exportedAt).toBe('string');
    // ISO-8601 sanity check: YYYY-MM-DDTHH:MM:SS.sssZ
    expect(parsed.exportedAt).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/);
    expect(Array.isArray(parsed.profiles)).toBe(true);
    expect(parsed.profiles).toHaveLength(2);
  });

  it('SECURITY: omits credentials, vaultId, keyVaultId, hasVaultCreds, authType, initialCommand', () => {
    seedProfiles();
    const json = exportProfilesJson();
    const parsed = JSON.parse(json);

    const FORBIDDEN = [
      'password', 'privateKey', 'passphrase',
      'vaultId', 'keyVaultId', 'hasVaultCreds',
      // The native client does not need authType (handled per-connect) and
      // initialCommand is a PWA-only concept right now.
      'authType', 'initialCommand',
    ];
    for (const profile of parsed.profiles) {
      for (const field of FORBIDDEN) {
        expect(profile).not.toHaveProperty(field);
      }
    }
  });

  it('preserves title, host, port, username, theme, color', () => {
    seedProfiles();
    const json = exportProfilesJson();
    const parsed = JSON.parse(json);

    expect(parsed.profiles[0]).toEqual({
      title: 'Dev Server',
      host: 'dev.example.com',
      port: 22,
      username: 'admin',
      theme: 'dark',
      color: '#ff8800',
    });
    // Second profile has no explicit color — field should be absent, not null/undefined.
    expect(parsed.profiles[1]).toEqual({
      title: 'Prod Server',
      host: 'prod.example.com',
      port: 2222,
      username: 'deploy',
      theme: 'nord',
    });
    expect(parsed.profiles[1]).not.toHaveProperty('color');
  });

  it('round-trip: parsing the export yields the same identity fields as input', () => {
    seedProfiles();
    const inputs = JSON.parse(localStorage.getItem('sshProfiles')!) as Array<{
      title: string; host: string; port: number; username: string;
      theme?: string; color?: string;
    }>;
    const json = exportProfilesJson();
    const parsed = JSON.parse(json) as { profiles: Array<{ title: string; host: string; port: number; username: string }> };

    expect(parsed.profiles).toHaveLength(inputs.length);
    for (let i = 0; i < inputs.length; i++) {
      expect(parsed.profiles[i]!.title).toBe(inputs[i]!.title);
      expect(parsed.profiles[i]!.host).toBe(inputs[i]!.host);
      expect(parsed.profiles[i]!.port).toBe(inputs[i]!.port);
      expect(parsed.profiles[i]!.username).toBe(inputs[i]!.username);
    }
  });

  it('synthesizes a title for profiles missing one', () => {
    storage.set('sshProfiles', JSON.stringify([
      { title: '', host: 'h.example', port: 22, username: 'me', authType: 'password', initialCommand: '', vaultId: 'v' },
    ]));
    const json = exportProfilesJson();
    const parsed = JSON.parse(json);
    expect(parsed.profiles[0]!.title).toBe('me@h.example');
  });

  it('defaults port to 22 when missing/falsy', () => {
    storage.set('sshProfiles', JSON.stringify([
      { title: 'Defaulty', host: 'h', port: 0, username: 'u', authType: 'password', initialCommand: '', vaultId: 'v' },
    ]));
    const json = exportProfilesJson();
    const parsed = JSON.parse(json);
    expect(parsed.profiles[0]!.port).toBe(22);
  });

  it('emits zero-profiles envelope when storage is empty', () => {
    const json = exportProfilesJson();
    const parsed = JSON.parse(json);
    expect(parsed.version).toBe(1);
    expect(parsed.profiles).toEqual([]);
  });
});

describe('#501: triggerProfilesDownload', () => {
  beforeEach(() => {
    storage.clear();
    clipboardWrites.length = 0;
    downloads.length = 0;
  });

  it('writes the export to the clipboard AND triggers a download', () => {
    seedProfiles();
    triggerProfilesDownload();

    // Clipboard path
    expect(clipboardWrites).toHaveLength(1);
    const clipParsed = JSON.parse(clipboardWrites[0]!);
    expect(clipParsed.version).toBe(1);
    expect(clipParsed.profiles).toHaveLength(2);

    // Download path
    expect(downloads).toHaveLength(1);
    expect(downloads[0]!.href).toBe('blob:mock');
    expect(downloads[0]!.download).toMatch(/^mobissh-profiles-.*\.json$/);
  });
});
