import { describe, it, expect, beforeEach, vi } from 'vitest';
import { webcrypto } from 'node:crypto';

// Node 18 needs crypto polyfill for Web Crypto API
vi.stubGlobal('crypto', webcrypto);

// Mock localStorage
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

// Mock minimal window/navigator for vault detection
vi.stubGlobal('location', { hostname: 'localhost' });

// Import after mocks are set up
const vault = await import('../vault.js');
const { appState } = await import('../state.js');

describe('vault crypto core', () => {
  beforeEach(() => {
    storage.clear();
    appState.vaultKey = null;
    appState.vaultMethod = null;
    appState.vaultIdleTimer = null;
  });

  describe('createVault + unlockWithPassword', () => {
    it('creates vault and sets DEK in appState', async () => {
      expect(vault.vaultExists()).toBe(false);

      await vault.createVault('testpass', false);

      expect(vault.vaultExists()).toBe(true);
      expect(appState.vaultKey).not.toBeNull();
      expect(appState.vaultMethod).toBe('master-pw');
    });

    it('unlocks vault with correct password after lock', async () => {
      await vault.createVault('mypass123', false);
      vault.lockVault();

      expect(appState.vaultKey).toBeNull();
      expect(vault.isVaultLocked()).toBe(true);

      const ok = await vault.unlockWithPassword('mypass123');
      expect(ok).toBe(true);
      expect(appState.vaultKey).not.toBeNull();
    });

    it('rejects wrong password', async () => {
      await vault.createVault('correct', false);
      vault.lockVault();

      const ok = await vault.unlockWithPassword('wrong');
      expect(ok).toBe(false);
      expect(appState.vaultKey).toBeNull();
    });

    it('supports empty-string edge case gracefully', async () => {
      // While UX prevents this, crypto layer should handle it
      await vault.createVault('', false);
      vault.lockVault();
      const ok = await vault.unlockWithPassword('');
      expect(ok).toBe(true);
    });
  });

  describe('vaultStore + vaultLoad round-trip', () => {
    it('encrypts and decrypts data correctly', async () => {
      await vault.createVault('pw', false);

      const data = { password: 'secret123', privateKey: 'pem-data-here' };
      await vault.vaultStore('entry1', data);

      const loaded = await vault.vaultLoad('entry1');
      expect(loaded).toEqual(data);
    });

    it('returns null for non-existent entry', async () => {
      await vault.createVault('pw', false);
      const loaded = await vault.vaultLoad('nonexistent');
      expect(loaded).toBeNull();
    });

    it('returns null when vault is locked', async () => {
      await vault.createVault('pw', false);
      await vault.vaultStore('entry1', { password: 'secret' });
      vault.lockVault();

      const loaded = await vault.vaultLoad('entry1');
      expect(loaded).toBeNull();
    });

    it('data survives lock/unlock cycle', async () => {
      await vault.createVault('pw', false);
      await vault.vaultStore('entry1', { password: 'secret' });
      vault.lockVault();

      await vault.unlockWithPassword('pw');
      const loaded = await vault.vaultLoad('entry1');
      expect(loaded).toEqual({ password: 'secret' });
    });
  });

  describe('vaultDelete', () => {
    it('removes an entry', async () => {
      await vault.createVault('pw', false);
      await vault.vaultStore('entry1', { password: 'a' });
      await vault.vaultStore('entry2', { password: 'b' });

      vault.vaultDelete('entry1');

      const loaded1 = await vault.vaultLoad('entry1');
      const loaded2 = await vault.vaultLoad('entry2');
      expect(loaded1).toBeNull();
      expect(loaded2).toEqual({ password: 'b' });
    });
  });

  describe('changePassword', () => {
    it('re-wraps DEK with new password', async () => {
      await vault.createVault('oldpass', false);
      await vault.vaultStore('entry1', { password: 'secret' });

      const ok = await vault.changePassword('oldpass', 'newpass');
      expect(ok).toBe(true);

      // Lock and unlock with new password
      vault.lockVault();
      const unlocked = await vault.unlockWithPassword('newpass');
      expect(unlocked).toBe(true);

      // Data still accessible
      const loaded = await vault.vaultLoad('entry1');
      expect(loaded).toEqual({ password: 'secret' });
    });

    it('rejects wrong old password', async () => {
      await vault.createVault('correct', false);

      const ok = await vault.changePassword('wrong', 'newpass');
      expect(ok).toBe(false);
    });

    it('old password no longer works after change', async () => {
      await vault.createVault('oldpass', false);
      await vault.changePassword('oldpass', 'newpass');
      vault.lockVault();

      const ok = await vault.unlockWithPassword('oldpass');
      expect(ok).toBe(false);
    });
  });

  describe('resetVault', () => {
    it('clears all vault data', async () => {
      await vault.createVault('pw', false);
      await vault.vaultStore('entry1', { password: 'secret' });

      vault.resetVault();

      expect(vault.vaultExists()).toBe(false);
      expect(vault.vaultHasData()).toBe(false);
      expect(appState.vaultKey).toBeNull();
      expect(appState.vaultMethod).toBeNull();
    });
  });

  describe('lockVault', () => {
    it('clears DEK from memory', async () => {
      await vault.createVault('pw', false);
      expect(appState.vaultKey).not.toBeNull();

      vault.lockVault();
      expect(appState.vaultKey).toBeNull();
      expect(appState.vaultIdleTimer).toBeNull();
    });
  });

  describe('state queries', () => {
    it('vaultExists returns false initially', () => {
      expect(vault.vaultExists()).toBe(false);
    });

    it('isVaultLocked returns false when no vault exists', () => {
      expect(vault.isVaultLocked()).toBe(false);
    });

    it('vaultHasData reflects encrypted entries', async () => {
      await vault.createVault('pw', false);
      expect(vault.vaultHasData()).toBe(false);

      await vault.vaultStore('entry1', { password: 'x' });
      expect(vault.vaultHasData()).toBe(true);
    });
  });

  describe('legacy vault detection', () => {
    it('detects legacy vault (sshVault without vaultMeta)', () => {
      storage.set('sshVault', JSON.stringify({ entry1: { iv: 'x', ct: 'y' } }));
      expect(vault.hasLegacyVault()).toBe(true);
    });

    it('does not flag new vault as legacy', async () => {
      await vault.createVault('pw', false);
      await vault.vaultStore('entry1', { password: 'x' });
      expect(vault.hasLegacyVault()).toBe(false);
    });
  });
});
