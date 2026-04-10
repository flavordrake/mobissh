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
    it('row-keys order: Esc Tab / - | ^C ^Z ^B ^D (editing + control)', () => {
      const row = DEFAULT_KEY_BAR_CONFIG.find((r) => r.id === 'row-keys');
      expect(row).toBeDefined();
      const ids = row!.buttons.map((b) => b.id);
      expect(ids).toEqual([
        'keyEsc', 'keyTab', 'keySlash', 'keyDash', 'keyPipe',
        'keyCtrlC', 'keyCtrlZ', 'keyCtrlB', 'keyCtrlD',
      ]);
    });

    it('row-nav order: arrows in T order (left up down right) then Home End PgUp PgDn', () => {
      const row = DEFAULT_KEY_BAR_CONFIG.find((r) => r.id === 'row-nav');
      expect(row).toBeDefined();
      const ids = row!.buttons.map((b) => b.id);
      expect(ids).toEqual([
        'keyLeft', 'keyUp', 'keyDown', 'keyRight',
        'keyHome', 'keyEnd', 'keyPgUp', 'keyPgDn',
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

  describe('#250: depth-2 has all buttons with T-arrow layout', () => {
    it('no buttons lost between depth 1 and depth 2 — all button IDs present across both rows', () => {
      const allIds = DEFAULT_KEY_BAR_CONFIG.flatMap((r) => r.buttons.map((b) => b.id));
      // All editing keys present
      expect(allIds).toContain('keyEsc');
      expect(allIds).toContain('keyTab');
      expect(allIds).toContain('keySlash');
      expect(allIds).toContain('keyDash');
      expect(allIds).toContain('keyPipe');
      // All control keys present
      expect(allIds).toContain('keyCtrlC');
      expect(allIds).toContain('keyCtrlZ');
      expect(allIds).toContain('keyCtrlB');
      expect(allIds).toContain('keyCtrlD');
      // All arrow keys present
      expect(allIds).toContain('keyLeft');
      expect(allIds).toContain('keyRight');
      expect(allIds).toContain('keyUp');
      expect(allIds).toContain('keyDown');
      // All navigation keys present
      expect(allIds).toContain('keyHome');
      expect(allIds).toContain('keyEnd');
      expect(allIds).toContain('keyPgUp');
      expect(allIds).toContain('keyPgDn');
    });

    it('row-nav arrows in T order: left up down right', () => {
      const row = DEFAULT_KEY_BAR_CONFIG.find((r) => r.id === 'row-nav');
      expect(row).toBeDefined();
      const arrowIds = row!.buttons.filter((b) =>
        ['keyLeft', 'keyUp', 'keyDown', 'keyRight'].includes(b.id)
      ).map((b) => b.id);
      expect(arrowIds).toEqual(['keyLeft', 'keyUp', 'keyDown', 'keyRight']);
    });

    it('control keys are in row-keys (row 1), not row-nav (row 2)', () => {
      const rowKeys = DEFAULT_KEY_BAR_CONFIG.find((r) => r.id === 'row-keys');
      const rowNav = DEFAULT_KEY_BAR_CONFIG.find((r) => r.id === 'row-nav');
      const rowKeyIds = rowKeys!.buttons.map((b) => b.id);
      const rowNavIds = rowNav!.buttons.map((b) => b.id);
      expect(rowKeyIds).toContain('keyCtrlC');
      expect(rowKeyIds).toContain('keyCtrlZ');
      expect(rowKeyIds).toContain('keyCtrlB');
      expect(rowKeyIds).toContain('keyCtrlD');
      expect(rowNavIds).not.toContain('keyCtrlC');
      expect(rowNavIds).not.toContain('keyCtrlZ');
      expect(rowNavIds).not.toContain('keyCtrlB');
      expect(rowNavIds).not.toContain('keyCtrlD');
    });
  });
});
