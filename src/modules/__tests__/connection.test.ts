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

// Mock vault module for _resolvePassphrase tests
vi.mock('../vault.js', () => ({
  vaultLoad: vi.fn(),
  createVault: vi.fn(),
  unlockVault: vi.fn(),
  vaultStore: vi.fn(),
  vaultDelete: vi.fn(),
  isVaultUnlocked: vi.fn(() => false),
}));

const { vaultLoad, vaultStore } = await import('../vault.js');
const vaultLoadMock = vi.mocked(vaultLoad);
const vaultStoreMock = vi.mocked(vaultStore);

const { _getPassphraseCache, _isKeyEncrypted, _resolvePassphrase } = await import('../connection.js');

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

describe('_resolvePassphrase (#418)', () => {
  const encryptedKey = [
    '-----BEGIN RSA PRIVATE KEY-----',
    'Proc-Type: 4,ENCRYPTED',
    'DEK-Info: AES-128-CBC,AABBCCDD',
    'dGVzdGRhdGE=',
    '-----END RSA PRIVATE KEY-----',
  ].join('\n');

  const unencryptedKey = [
    '-----BEGIN RSA PRIVATE KEY-----',
    'dGVzdGRhdGE=',
    '-----END RSA PRIVATE KEY-----',
  ].join('\n');

  beforeEach(() => {
    _getPassphraseCache().clear();
    vaultLoadMock.mockReset();
  });

  it('returns ok immediately for password auth profiles', async () => {
    const profile = { name: 'test', host: 'h', port: 22, username: 'u', authType: 'password' as const, password: 'pw' };
    expect(await _resolvePassphrase(profile)).toBe('ok');
  });

  it('returns ok for key auth with unencrypted key', async () => {
    const profile = { name: 'test', host: 'h', port: 22, username: 'u', authType: 'key' as const, privateKey: unencryptedKey };
    expect(await _resolvePassphrase(profile)).toBe('ok');
  });

  it('resolves passphrase from cache for encrypted key', async () => {
    _getPassphraseCache().set('vault-1', 'cached-pass');
    const profile = { name: 'test', host: 'h', port: 22, username: 'u', authType: 'key' as const, privateKey: encryptedKey, keyVaultId: 'vault-1' };
    expect(await _resolvePassphrase(profile)).toBe('ok');
    expect(profile.passphrase).toBe('cached-pass');
  });

  it('loads key from vault when privateKey is missing', async () => {
    vaultLoadMock.mockResolvedValue({ data: unencryptedKey });
    const profile = { name: 'test', host: 'h', port: 22, username: 'u', authType: 'key' as const, keyVaultId: 'vault-1' };
    expect(await _resolvePassphrase(profile)).toBe('ok');
    expect(profile.privateKey).toBe(unencryptedKey);
  });

  it('returns no-key when vault load fails', async () => {
    vaultLoadMock.mockResolvedValue(null);
    const profile = { name: 'test', host: 'h', port: 22, username: 'u', authType: 'key' as const, keyVaultId: 'vault-1' };
    expect(await _resolvePassphrase(profile)).toBe('no-key');
  });

  it('prompts user when encrypted key has no cached passphrase', async () => {
    // Simulate user clicking OK with a passphrase
    mockOkBtn.addEventListener.mockImplementation((_event: string, handler: () => void) => {
      mockInput.value = 'user-entered-pass';
      setTimeout(handler, 0);
    });

    const profile = { name: 'test', host: 'h', port: 22, username: 'u', authType: 'key' as const, privateKey: encryptedKey, keyVaultId: 'vault-2' };
    const result = await _resolvePassphrase(profile);
    expect(result).toBe('ok');
    expect(profile.passphrase).toBe('user-entered-pass');
    // Passphrase should be cached
    expect(_getPassphraseCache().get('vault-2')).toBe('user-entered-pass');

    // Clean up mock
    mockOkBtn.addEventListener.mockReset();
  });

  it('returns cancelled when user dismisses passphrase prompt', async () => {
    // Simulate user clicking Cancel
    mockCancelBtn.addEventListener.mockImplementation((_event: string, handler: () => void) => {
      setTimeout(handler, 0);
    });

    const profile = { name: 'test', host: 'h', port: 22, username: 'u', authType: 'key' as const, privateKey: encryptedKey, keyVaultId: 'vault-3' };
    const result = await _resolvePassphrase(profile);
    expect(result).toBe('cancelled');

    // Clean up mock
    mockCancelBtn.addEventListener.mockReset();
  });

  it('skips resolution when passphrase is already set on profile', async () => {
    const profile = { name: 'test', host: 'h', port: 22, username: 'u', authType: 'key' as const, privateKey: encryptedKey, passphrase: 'already-set' };
    expect(await _resolvePassphrase(profile)).toBe('ok');
    expect(profile.passphrase).toBe('already-set');
  });
});

describe('Vault passphrase persistence (#426)', () => {
  const encryptedKey = [
    '-----BEGIN RSA PRIVATE KEY-----',
    'Proc-Type: 4,ENCRYPTED',
    'DEK-Info: AES-128-CBC,AABBCCDD',
    'dGVzdGRhdGE=',
    '-----END RSA PRIVATE KEY-----',
  ].join('\n');

  beforeEach(() => {
    _getPassphraseCache().clear();
    vaultLoadMock.mockReset();
    vaultStoreMock.mockReset();
  });

  it('loads passphrase from vault when not in memory cache', async () => {
    // Vault has both key data and passphrase stored
    vaultLoadMock.mockResolvedValue({ data: encryptedKey, passphrase: 'vault-pass' });
    const profile = { name: 'test', host: 'h', port: 22, username: 'u', authType: 'key' as const, keyVaultId: 'vault-1' };
    const result = await _resolvePassphrase(profile);
    expect(result).toBe('ok');
    expect(profile.passphrase).toBe('vault-pass');
    // Should also populate in-memory cache
    expect(_getPassphraseCache().get('vault-1')).toBe('vault-pass');
  });

  it('stores passphrase to vault after user prompt', async () => {
    // First call: load key data (no passphrase stored yet)
    vaultLoadMock.mockResolvedValueOnce({ data: encryptedKey });
    // Second call: check vault for persisted passphrase (none yet)
    vaultLoadMock.mockResolvedValueOnce({ data: encryptedKey });
    // Third call: load existing vault entry for storing passphrase alongside key
    vaultLoadMock.mockResolvedValueOnce({ data: encryptedKey });
    vaultStoreMock.mockResolvedValue(undefined);

    // Simulate user clicking OK with a passphrase
    mockOkBtn.addEventListener.mockImplementation((_event: string, handler: () => void) => {
      mockInput.value = 'new-pass';
      setTimeout(handler, 0);
    });

    const profile = { name: 'test', host: 'h', port: 22, username: 'u', authType: 'key' as const, keyVaultId: 'vault-2' };
    const result = await _resolvePassphrase(profile);
    expect(result).toBe('ok');
    expect(profile.passphrase).toBe('new-pass');
    // Should have stored passphrase in vault
    expect(vaultStoreMock).toHaveBeenCalledWith('vault-2', { data: encryptedKey, passphrase: 'new-pass' });

    mockOkBtn.addEventListener.mockReset();
  });

  it('uses in-memory cache without vault lookup when cached', async () => {
    _getPassphraseCache().set('vault-3', 'mem-pass');
    const profile = { name: 'test', host: 'h', port: 22, username: 'u', authType: 'key' as const, privateKey: encryptedKey, keyVaultId: 'vault-3' };
    const result = await _resolvePassphrase(profile);
    expect(result).toBe('ok');
    expect(profile.passphrase).toBe('mem-pass');
    // vaultLoad should not have been called (key already on profile, passphrase from cache)
    expect(vaultLoadMock).not.toHaveBeenCalled();
  });
});

describe('_isKeyEncrypted (#97)', () => {
  it('detects old-format PEM encrypted key (contains ENCRYPTED)', () => {
    const key = [
      '-----BEGIN RSA PRIVATE KEY-----',
      'Proc-Type: 4,ENCRYPTED',
      'DEK-Info: AES-128-CBC,AABBCCDD',
      'dGVzdGRhdGE=',
      '-----END RSA PRIVATE KEY-----',
    ].join('\n');
    expect(_isKeyEncrypted(key)).toBe(true);
  });

  it('returns false for old-format unencrypted PEM key', () => {
    const key = [
      '-----BEGIN RSA PRIVATE KEY-----',
      'dGVzdGRhdGE=',
      '-----END RSA PRIVATE KEY-----',
    ].join('\n');
    expect(_isKeyEncrypted(key)).toBe(false);
  });

  it('detects new-format OpenSSH encrypted key (aes256-ctr cipher)', () => {
    const key = [
      '-----BEGIN OPENSSH PRIVATE KEY-----',
      'b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0',
      '-----END OPENSSH PRIVATE KEY-----',
    ].join('\n');
    expect(_isKeyEncrypted(key)).toBe(true);
  });

  it('returns false for new-format OpenSSH unencrypted key (none cipher)', () => {
    const key = [
      '-----BEGIN OPENSSH PRIVATE KEY-----',
      'b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQ==',
      '-----END OPENSSH PRIVATE KEY-----',
    ].join('\n');
    expect(_isKeyEncrypted(key)).toBe(false);
  });

  it('defaults to encrypted when OpenSSH key has invalid/truncated data', () => {
    const key = [
      '-----BEGIN OPENSSH PRIVATE KEY-----',
      'AAAA',
      '-----END OPENSSH PRIVATE KEY-----',
    ].join('\n');
    expect(_isKeyEncrypted(key)).toBe(true);
  });
});
