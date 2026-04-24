import { describe, it, expect, beforeEach, vi } from 'vitest';

// Mock localStorage before importing modules
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
vi.stubGlobal('location', { hostname: 'localhost', host: 'localhost:8081', reload: vi.fn() });

let lastCreatedElement: Record<string, unknown> = {};
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
    lastCreatedElement = {
      href: '',
      download: '',
      click: vi.fn(),
      className: '',
      textContent: '',
      innerHTML: '',
      appendChild: vi.fn(),
      addEventListener: vi.fn(),
      querySelector: vi.fn(),
    };
    return lastCreatedElement;
  }),
  fonts: { ready: Promise.resolve() },
  body: { appendChild: vi.fn(), removeChild: vi.fn(), classList: { add: vi.fn(), remove: vi.fn(), toggle: vi.fn() } },
});

vi.stubGlobal('window', {
  addEventListener: vi.fn(),
  visualViewport: null,
  outerHeight: 900,
});

vi.stubGlobal('Notification', { permission: 'granted' });
vi.stubGlobal('getComputedStyle', () => ({ getPropertyValue: () => '' }));
let lastBlobParts: unknown[] = [];
vi.stubGlobal('Blob', class {
  parts: unknown[];
  constructor(parts: unknown[]) { this.parts = parts; lastBlobParts = parts; }
});

// Keep real URL constructor but add blob methods
const RealURL = globalThis.URL;
vi.stubGlobal('URL', Object.assign(
  function UrlShim(...args: ConstructorParameters<typeof RealURL>) { return new RealURL(...args); },
  {
    prototype: RealURL.prototype,
    createObjectURL: vi.fn(() => 'blob:test'),
    revokeObjectURL: vi.fn(),
  }
));

let toastMessages: string[] = [];
const { exportBackup, importBackup } = await import('../settings.js');
const { initSettings } = await import('../settings.js');
initSettings({
  toast: (msg: string) => { toastMessages.push(msg); },
  applyFontSize: vi.fn(),
  applyTheme: vi.fn(),
});

describe('backup export (#337)', () => {
  beforeEach(() => {
    storage.clear();
    toastMessages = [];
    lastBlobParts = [];
  });

  it('produces valid JSON with version, profiles, and vault fields', () => {
    storage.set('sshProfiles', JSON.stringify([
      { name: 'test', host: 'example.com', port: 22, username: 'user', authType: 'password', vaultId: 'v1', initialCommand: '' },
    ]));
    storage.set('sshVault', '{"v1":{"iv":"abc","ct":"def"}}');
    storage.set('vaultMeta', '{"salt":"xyz","dekPw":{"iv":"a","ct":"b"}}');

    exportBackup();

    const jsonStr = lastBlobParts[0] as string;
    const parsed = JSON.parse(jsonStr);
    expect(parsed.version).toBe(1);
    expect(parsed.exported).toBeDefined();
    expect(parsed.profiles).toHaveLength(1);
    expect(parsed.profiles[0].host).toBe('example.com');
    expect(parsed.vault.encrypted).toBe('{"v1":{"iv":"abc","ct":"def"}}');
    expect(parsed.vault.meta).toBe('{"salt":"xyz","dekPw":{"iv":"a","ct":"b"}}');
  });

  it('exports empty profiles array when no profiles exist', () => {
    exportBackup();

    const jsonStr = lastBlobParts[0] as string;
    const parsed = JSON.parse(jsonStr);
    expect(parsed.profiles).toEqual([]);
    expect(parsed.version).toBe(1);
  });

  it('triggers file download with correct filename', () => {
    exportBackup();
    expect(lastCreatedElement.download).toMatch(/^mobissh-backup-\d{4}-\d{2}-\d{2}\.json$/);
    expect((lastCreatedElement.click as ReturnType<typeof vi.fn>)).toHaveBeenCalled();
  });
});

describe('backup import (#337)', () => {
  beforeEach(() => {
    storage.clear();
    toastMessages = [];
  });

  it('imports profiles via upsert (no duplicates)', async () => {
    storage.set('sshProfiles', JSON.stringify([
      { name: 'existing', host: 'a.com', port: 22, username: 'root', authType: 'password', vaultId: 'v1', initialCommand: '' },
    ]));

    const backup = {
      version: 1,
      exported: '2026-03-27T00:00:00Z',
      profiles: [
        { name: 'updated', host: 'a.com', port: 22, username: 'root', authType: 'key', vaultId: 'v2', initialCommand: '' },
        { name: 'new', host: 'b.com', port: 22, username: 'admin', authType: 'password', vaultId: 'v3', initialCommand: '' },
      ],
      vault: { encrypted: null, meta: null },
    };
    const file = { text: () => Promise.resolve(JSON.stringify(backup)) } as unknown as File;

    await importBackup(file);

    const profiles = JSON.parse(storage.get('sshProfiles')!);
    expect(profiles).toHaveLength(2);
    // Profile schema migrated name → title in #425; getProfiles() (called by
    // importBackup and the subsequent loadProfiles()) migrates on read.
    expect(profiles[0].title ?? profiles[0].name).toBe('updated');
    expect(profiles[1].title ?? profiles[1].name).toBe('new');
  });

  it('shows error toast on invalid JSON', async () => {
    const file = { text: () => Promise.resolve('not json{{{') } as unknown as File;
    await importBackup(file);
    expect(toastMessages).toContain('Invalid backup file — not valid JSON.');
  });

  it('shows error toast on unsupported version', async () => {
    const backup = { version: 99, profiles: [], vault: { encrypted: null, meta: null } };
    const file = { text: () => Promise.resolve(JSON.stringify(backup)) } as unknown as File;
    await importBackup(file);
    expect(toastMessages[0]).toMatch(/Unsupported backup version/);
  });

  it('imports vault encrypted blob without decrypting', async () => {
    const vaultBlob = '{"v1":{"iv":"abc","ct":"def"}}';
    const vaultMeta = '{"salt":"xyz","dekPw":{"iv":"a","ct":"b"}}';
    const backup = {
      version: 1,
      exported: '2026-03-27T00:00:00Z',
      profiles: [],
      vault: { encrypted: vaultBlob, meta: vaultMeta },
    };
    const file = { text: () => Promise.resolve(JSON.stringify(backup)) } as unknown as File;

    await importBackup(file);

    expect(storage.get('sshVault')).toBe(vaultBlob);
    // Meta is rewritten (dekBio stripped) but the password-wrap survives unchanged
    const importedMeta = JSON.parse(storage.get('vaultMeta')!);
    expect(importedMeta.salt).toBe('xyz');
    expect(importedMeta.dekPw).toEqual({ iv: 'a', ct: 'b' });
  });

  // Regression: vault-import-reprompt
  // dekBio is device-specific (wrapped with KEK from THIS device's WebAuthn PRF).
  // Importing it from another device produces a wrap that cannot be unwrapped here,
  // causing every fingerprint touch to silently fail and fall through to a manual
  // password prompt. The fix strips dekBio at import time and clears any stale
  // local WebAuthn handles so the unlock path skips bio entirely.
  it('strips dekBio from imported vaultMeta to prevent broken bio prompts', async () => {
    storage.set('webauthnCredId', 'stale-cred-from-previous-enrollment');
    storage.set('webauthnPrfSalt', 'stale-salt');

    const vaultMeta = JSON.stringify({
      salt: 'xyz',
      dekPw: { iv: 'a', ct: 'b' },
      dekBio: { iv: 'OLD-DEVICE-IV', ct: 'OLD-DEVICE-CT' },
    });
    const backup = {
      version: 1,
      exported: '2026-03-27T00:00:00Z',
      profiles: [],
      vault: { encrypted: '{"v1":{"iv":"abc","ct":"def"}}', meta: vaultMeta },
    };
    const file = { text: () => Promise.resolve(JSON.stringify(backup)) } as unknown as File;

    await importBackup(file);

    const importedMeta = JSON.parse(storage.get('vaultMeta')!);
    expect(importedMeta.dekBio).toBeUndefined();
    expect(importedMeta.dekPw).toEqual({ iv: 'a', ct: 'b' });
    expect(importedMeta.salt).toBe('xyz');
    // Stale local WebAuthn handles cleared so tryUnlockVault doesn't attempt bio
    expect(storage.get('webauthnCredId')).toBeUndefined();
    expect(storage.get('webauthnPrfSalt')).toBeUndefined();
  });

  it('toast tells the user to re-enable Touch ID after importing a bio-enrolled backup', async () => {
    const vaultMeta = JSON.stringify({
      salt: 'xyz',
      dekPw: { iv: 'a', ct: 'b' },
      dekBio: { iv: 'old', ct: 'wrap' },
    });
    const backup = {
      version: 1,
      exported: '2026-03-27T00:00:00Z',
      profiles: [],
      vault: { encrypted: '{"v1":{"iv":"abc","ct":"def"}}', meta: vaultMeta },
    };
    const file = { text: () => Promise.resolve(JSON.stringify(backup)) } as unknown as File;

    await importBackup(file);

    expect(toastMessages[0]).toMatch(/re-enable Touch ID/);
  });

  // Regression: import doesn't refresh Connect panel
  // After importBackup writes new profiles to localStorage, the Connect panel
  // must re-render — otherwise the user sees the cold-start "Add Connection"
  // empty state until they fully kill and restart the app.
  it('re-renders the Connect panel (calls loadProfiles) after a successful import', async () => {
    // Stand up minimal DOM elements that loadProfiles() touches.
    // It early-returns when #profileList is missing, so providing it forces
    // the side effect to run.
    const fakeProfileList: Record<string, unknown> = { innerHTML: '__PRE__' };
    const fakeSessionList: Record<string, unknown> = { innerHTML: '' };
    const fakeFormSection: Record<string, unknown> = { classList: { add: vi.fn(), remove: vi.fn() } };
    const fakeNewConnBtn: Record<string, unknown> = { classList: { add: vi.fn(), remove: vi.fn() } };

    const realDoc = (globalThis as { document: { getElementById: (id: string) => unknown } }).document;
    const origGetElementById = realDoc.getElementById;
    realDoc.getElementById = (id: string): unknown => {
      if (id === 'profileList') return fakeProfileList;
      if (id === 'activeSessionList') return fakeSessionList;
      if (id === 'connect-form-section') return fakeFormSection;
      if (id === 'newConnBtn') return fakeNewConnBtn;
      return null;
    };

    try {
      const backup = {
        version: 1,
        exported: '2026-04-07T00:00:00Z',
        profiles: [
          { name: 'imported', host: 'imported.example.com', port: 22, username: 'me', authType: 'password', vaultId: 'v1', initialCommand: '' },
        ],
        vault: { encrypted: null, meta: null },
      };
      const file = { text: () => Promise.resolve(JSON.stringify(backup)) } as unknown as File;

      await importBackup(file);

      // loadProfiles wrote new HTML — proves the re-render fired
      expect(fakeProfileList.innerHTML).not.toBe('__PRE__');
    } finally {
      realDoc.getElementById = origGetElementById;
    }
  });

  it('imports vault meta without dekBio unchanged (no spurious "Touch ID" message)', async () => {
    const vaultMeta = JSON.stringify({
      salt: 'xyz',
      dekPw: { iv: 'a', ct: 'b' },
    });
    const backup = {
      version: 1,
      exported: '2026-03-27T00:00:00Z',
      profiles: [],
      vault: { encrypted: '{"v1":{"iv":"abc","ct":"def"}}', meta: vaultMeta },
    };
    const file = { text: () => Promise.resolve(JSON.stringify(backup)) } as unknown as File;

    await importBackup(file);

    expect(toastMessages[0]).not.toMatch(/Touch ID/);
    expect(toastMessages[0]).toMatch(/credentials imported \(enter vault passphrase/);
  });

  it('shows summary toast with profile count', async () => {
    const backup = {
      version: 1,
      exported: '2026-03-27T00:00:00Z',
      profiles: [
        { name: 'srv1', host: 'a.com', port: 22, username: 'root', authType: 'password', vaultId: 'v1', initialCommand: '' },
        { name: 'srv2', host: 'b.com', port: 22, username: 'admin', authType: 'password', vaultId: 'v2', initialCommand: '' },
      ],
      vault: { encrypted: '{"data":"enc"}', meta: null },
    };
    const file = { text: () => Promise.resolve(JSON.stringify(backup)) } as unknown as File;

    await importBackup(file);

    expect(toastMessages[0]).toMatch(/Imported 2 profiles/);
    expect(toastMessages[0]).toMatch(/credentials imported/);
  });
});
