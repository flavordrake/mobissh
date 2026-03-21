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

const { DEFAULT_KEY_BAR_CONFIG } = await import('../keybar-config.js');

describe('issues #225/#226: keybar fixes', () => {
  beforeEach(() => {
    storage.clear();
  });

  describe('#226: key order and label format', () => {
    it('row-keys order: Esc ^C ^Z Tab / - |', () => {
      const row = DEFAULT_KEY_BAR_CONFIG.find((r) => r.id === 'row-keys');
      expect(row).toBeDefined();
      const ids = row!.buttons.map((b) => b.id);
      expect(ids).toEqual([
        'keyEsc', 'keyCtrlC', 'keyCtrlZ', 'keyTab',
        'keySlash', 'keyDash', 'keyPipe',
      ]);
    });

    it('row-nav order: arrows Home End PgUp PgDn ^B ^D', () => {
      const row = DEFAULT_KEY_BAR_CONFIG.find((r) => r.id === 'row-nav');
      expect(row).toBeDefined();
      const ids = row!.buttons.map((b) => b.id);
      expect(ids).toEqual([
        'keyLeft', 'keyRight', 'keyUp', 'keyDown',
        'keyHome', 'keyEnd', 'keyPgUp', 'keyPgDn',
        'keyCtrlB', 'keyCtrlD',
      ]);
    });

    it('control key labels use ^X format', () => {
      const allButtons = DEFAULT_KEY_BAR_CONFIG.flatMap((r) => r.buttons);
      const ctrlC = allButtons.find((b) => b.id === 'keyCtrlC');
      const ctrlZ = allButtons.find((b) => b.id === 'keyCtrlZ');
      const ctrlB = allButtons.find((b) => b.id === 'keyCtrlB');
      const ctrlD = allButtons.find((b) => b.id === 'keyCtrlD');
      expect(ctrlC!.label).toBe('^C');
      expect(ctrlZ!.label).toBe('^Z');
      expect(ctrlB!.label).toBe('^B');
      expect(ctrlD!.label).toBe('^D');
    });

    it('^B sends correct sequence (\\x02)', () => {
      const allButtons = DEFAULT_KEY_BAR_CONFIG.flatMap((r) => r.buttons);
      const ctrlB = allButtons.find((b) => b.id === 'keyCtrlB');
      expect(ctrlB).toBeDefined();
      expect(ctrlB!.sequence).toBe('\x02');
    });

    it('^D sends correct sequence (\\x04)', () => {
      const allButtons = DEFAULT_KEY_BAR_CONFIG.flatMap((r) => r.buttons);
      const ctrlD = allButtons.find((b) => b.id === 'keyCtrlD');
      expect(ctrlD).toBeDefined();
      expect(ctrlD!.sequence).toBe('\x04');
    });

    it('Esc is in row-keys (first position), not row-nav', () => {
      const rowKeys = DEFAULT_KEY_BAR_CONFIG.find((r) => r.id === 'row-keys');
      const rowNav = DEFAULT_KEY_BAR_CONFIG.find((r) => r.id === 'row-nav');
      expect(rowKeys!.buttons[0].id).toBe('keyEsc');
      const navIds = rowNav!.buttons.map((b) => b.id);
      expect(navIds).not.toContain('keyEsc');
    });
  });
});
