import { describe, it, expect, beforeEach, vi } from 'vitest';

// Mock localStorage before importing the module
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

const {
  loadKeyBarConfig,
  saveKeyBarConfig,
  resetKeyBarConfig,
  DEFAULT_KEY_BAR_CONFIG,
} = await import('../keybar-config.js');

describe('keybar-config', () => {
  beforeEach(() => {
    storage.clear();
  });

  describe('DEFAULT_KEY_BAR_CONFIG', () => {
    it('has two rows', () => {
      expect(DEFAULT_KEY_BAR_CONFIG).toHaveLength(2);
    });

    it('row-keys contains editing keys', () => {
      const row = DEFAULT_KEY_BAR_CONFIG.find((r) => r.id === 'row-keys');
      expect(row).toBeDefined();
      const ids = row!.buttons.map((b) => b.id);
      expect(ids).toContain('keyTab');
      expect(ids).toContain('keySlash');
      expect(ids).toContain('keyPipe');
      expect(ids).toContain('keyDash');
    });

    it('row-nav contains arrow and navigation keys (no control keys)', () => {
      const row = DEFAULT_KEY_BAR_CONFIG.find((r) => r.id === 'row-nav');
      expect(row).toBeDefined();
      const ids = row!.buttons.map((b) => b.id);
      expect(ids).toContain('keyUp');
      expect(ids).toContain('keyDown');
      expect(ids).toContain('keyLeft');
      expect(ids).toContain('keyRight');
      expect(ids).toContain('keyHome');
      expect(ids).toContain('keyEnd');
      expect(ids).toContain('keyPgUp');
      expect(ids).toContain('keyPgDn');
    });

    it('row-keys contains control keys (^C ^Z ^B ^D)', () => {
      const row = DEFAULT_KEY_BAR_CONFIG.find((r) => r.id === 'row-keys');
      expect(row).toBeDefined();
      const ids = row!.buttons.map((b) => b.id);
      expect(ids).toContain('keyCtrlC');
      expect(ids).toContain('keyCtrlZ');
      expect(ids).toContain('keyCtrlB');
      expect(ids).toContain('keyCtrlD');
    });

    it('sequences match expected terminal escape codes', () => {
      const navRow = DEFAULT_KEY_BAR_CONFIG.find((r) => r.id === 'row-nav')!;
      const up = navRow.buttons.find((b) => b.id === 'keyUp');
      expect(up?.sequence).toBe('\x1b[A');
      const keysRow = DEFAULT_KEY_BAR_CONFIG.find((r) => r.id === 'row-keys')!;
      const esc = keysRow.buttons.find((b) => b.id === 'keyEsc');
      expect(esc?.sequence).toBe('\x1b');
    });
  });

  describe('loadKeyBarConfig', () => {
    it('returns defaults when localStorage is empty', () => {
      const config = loadKeyBarConfig();
      expect(config).toEqual(DEFAULT_KEY_BAR_CONFIG);
    });

    it('returns saved config when present and valid', () => {
      const custom = [
        { id: 'row-custom', buttons: [{ id: 'keyF1', label: 'F1', sequence: '\x1bOP' }] },
      ];
      storage.set('keyBarConfig', JSON.stringify(custom));
      const config = loadKeyBarConfig();
      expect(config).toEqual(custom);
    });

    it('returns defaults when stored data is corrupt JSON', () => {
      storage.set('keyBarConfig', '{not-valid-json}');
      const config = loadKeyBarConfig();
      expect(config).toEqual(DEFAULT_KEY_BAR_CONFIG);
    });

    it('returns defaults when stored data fails schema validation (not array)', () => {
      storage.set('keyBarConfig', JSON.stringify({ id: 'bad' }));
      const config = loadKeyBarConfig();
      expect(config).toEqual(DEFAULT_KEY_BAR_CONFIG);
    });

    it('returns defaults when a row is missing id', () => {
      const bad = [{ buttons: [{ id: 'k1', label: 'K', sequence: 'k' }] }];
      storage.set('keyBarConfig', JSON.stringify(bad));
      const config = loadKeyBarConfig();
      expect(config).toEqual(DEFAULT_KEY_BAR_CONFIG);
    });

    it('returns defaults when a button is missing sequence', () => {
      const bad = [{ id: 'row-x', buttons: [{ id: 'k1', label: 'K' }] }];
      storage.set('keyBarConfig', JSON.stringify(bad));
      const config = loadKeyBarConfig();
      expect(config).toEqual(DEFAULT_KEY_BAR_CONFIG);
    });
  });

  describe('saveKeyBarConfig', () => {
    it('persists config to localStorage', () => {
      const custom = [
        { id: 'row-custom', buttons: [{ id: 'keyF1', label: 'F1', sequence: '\x1bOP' }] },
      ];
      saveKeyBarConfig(custom);
      const raw = storage.get('keyBarConfig');
      expect(raw).toBeDefined();
      expect(JSON.parse(raw!)).toEqual(custom);
    });

    it('round-trips through load after save', () => {
      saveKeyBarConfig(DEFAULT_KEY_BAR_CONFIG);
      const loaded = loadKeyBarConfig();
      expect(loaded).toEqual(DEFAULT_KEY_BAR_CONFIG);
    });
  });

  describe('resetKeyBarConfig', () => {
    it('removes saved config from localStorage', () => {
      saveKeyBarConfig(DEFAULT_KEY_BAR_CONFIG);
      expect(storage.has('keyBarConfig')).toBe(true);
      resetKeyBarConfig();
      expect(storage.has('keyBarConfig')).toBe(false);
    });

    it('causes loadKeyBarConfig to return defaults after reset', () => {
      const custom = [
        { id: 'row-x', buttons: [{ id: 'k1', label: 'K1', sequence: 'k' }] },
      ];
      saveKeyBarConfig(custom);
      resetKeyBarConfig();
      const config = loadKeyBarConfig();
      expect(config).toEqual(DEFAULT_KEY_BAR_CONFIG);
    });
  });
});
