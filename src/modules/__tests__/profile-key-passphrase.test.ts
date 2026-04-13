/**
 * Regression test for #435: connectFromProfile must load passphrase
 * from the key vault record alongside the private key data.
 */
import { describe, it, expect, beforeEach, vi } from 'vitest';
import type { SSHProfile } from '../types.js';

// Stub browser globals before any module imports
vi.stubGlobal('crypto', { randomUUID: () => 'test-uuid-1234' });

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

vi.stubGlobal('document', {
  getElementById: () => null,
  querySelector: () => null,
  addEventListener: vi.fn(),
  visibilityState: 'visible',
});

vi.stubGlobal('window', {
  addEventListener: vi.fn(),
});

// Track the SSHProfile passed to connect()
let capturedProfile: SSHProfile | null = null;

vi.mock('../connection.js', () => ({
  connect: vi.fn(async (profile: SSHProfile) => { capturedProfile = profile; }),
}));

vi.mock('../vault.js', () => ({
  vaultLoad: vi.fn(),
  vaultStore: vi.fn(),
  vaultDelete: vi.fn(),
  createVault: vi.fn(),
  unlockVault: vi.fn(),
  isVaultUnlocked: vi.fn(() => false),
}));

vi.mock('../vault-ui.js', () => ({
  ensureVaultKeyWithUI: vi.fn(async () => true),
}));

// Provide a vaultKey so connectFromProfile skips the ensureVaultKeyWithUI gate
vi.mock('../state.js', async () => {
  const actual = await vi.importActual<typeof import('../state.js')>('../state.js');
  return {
    ...actual,
    appState: {
      ...actual.appState,
      vaultKey: {} as CryptoKey,  // truthy — vault is "unlocked"
    },
    isSessionConnected: actual.isSessionConnected,
  };
});

const { vaultLoad } = await import('../vault.js');
const vaultLoadMock = vi.mocked(vaultLoad);

const { connectFromProfile } = await import('../profiles.js');

describe('connectFromProfile key passphrase (#435)', () => {
  beforeEach(() => {
    storage.clear();
    capturedProfile = null;
    vaultLoadMock.mockReset();
  });

  it('loads passphrase from key vault record alongside private key', async () => {
    // Set up a profile with keyVaultId (stored key reference)
    const profiles = [{
      title: 'Test Server',
      host: 'example.com',
      port: 22,
      username: 'user',
      authType: 'key',
      initialCommand: '',
      vaultId: 'profile-vault-1',
      keyVaultId: 'key-vault-1',
      hasVaultCreds: false,
    }];
    storage.set('sshProfiles', JSON.stringify(profiles));

    // Vault record for the key includes both data and passphrase
    vaultLoadMock.mockResolvedValue({ data: '-----BEGIN RSA PRIVATE KEY-----\ntest\n-----END RSA PRIVATE KEY-----', passphrase: 'my-secret-pass' });

    const result = await connectFromProfile(0);

    expect(result).toBe(true);
    expect(capturedProfile).not.toBeNull();
    expect(capturedProfile!.privateKey).toBe('-----BEGIN RSA PRIVATE KEY-----\ntest\n-----END RSA PRIVATE KEY-----');
    expect(capturedProfile!.passphrase).toBe('my-secret-pass');
  });

  it('sets keyVaultId on SSHProfile so _resolvePassphrase can use it', async () => {
    const profiles = [{
      title: 'Test Server',
      host: 'example.com',
      port: 22,
      username: 'user',
      authType: 'key',
      initialCommand: '',
      vaultId: 'profile-vault-2',
      keyVaultId: 'key-vault-2',
      hasVaultCreds: false,
    }];
    storage.set('sshProfiles', JSON.stringify(profiles));

    vaultLoadMock.mockResolvedValue({ data: '-----BEGIN RSA PRIVATE KEY-----\ntest\n-----END RSA PRIVATE KEY-----' });

    await connectFromProfile(0);

    expect(capturedProfile).not.toBeNull();
    expect(capturedProfile!.keyVaultId).toBe('key-vault-2');
  });

  it('does not set passphrase when vault record has no passphrase', async () => {
    const profiles = [{
      title: 'Test Server',
      host: 'example.com',
      port: 22,
      username: 'user',
      authType: 'key',
      initialCommand: '',
      vaultId: 'profile-vault-3',
      keyVaultId: 'key-vault-3',
      hasVaultCreds: false,
    }];
    storage.set('sshProfiles', JSON.stringify(profiles));

    // Vault record has key data but no passphrase
    vaultLoadMock.mockResolvedValue({ data: '-----BEGIN RSA PRIVATE KEY-----\ntest\n-----END RSA PRIVATE KEY-----' });

    await connectFromProfile(0);

    expect(capturedProfile).not.toBeNull();
    expect(capturedProfile!.privateKey).toBe('-----BEGIN RSA PRIVATE KEY-----\ntest\n-----END RSA PRIVATE KEY-----');
    expect(capturedProfile!.passphrase).toBeUndefined();
  });
});
