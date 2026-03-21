import { describe, it, expect, beforeEach, vi } from 'vitest';
import { readFileSync } from 'fs';
import { resolve } from 'path';

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

describe('issue-217: slim session menu', () => {
  beforeEach(() => {
    storage.clear();
  });

  describe('key bar has Ctrl+C and Ctrl+Z', () => {
    it('row-keys contains keyCtrlC with correct sequence', () => {
      const row = DEFAULT_KEY_BAR_CONFIG.find((r) => r.id === 'row-keys');
      expect(row).toBeDefined();
      const ctrlC = row!.buttons.find((b) => b.id === 'keyCtrlC');
      expect(ctrlC).toBeDefined();
      expect(ctrlC!.sequence).toBe('\x03');
      expect(ctrlC!.label).toBe('C-c');
    });

    it('row-keys contains keyCtrlZ with correct sequence', () => {
      const row = DEFAULT_KEY_BAR_CONFIG.find((r) => r.id === 'row-keys');
      expect(row).toBeDefined();
      const ctrlZ = row!.buttons.find((b) => b.id === 'keyCtrlZ');
      expect(ctrlZ).toBeDefined();
      expect(ctrlZ!.sequence).toBe('\x1a');
      expect(ctrlZ!.label).toBe('C-z');
    });
  });

  describe('session menu HTML', () => {
    const html = readFileSync(resolve(__dirname, '../../../public/index.html'), 'utf-8');

    it('does not contain Ctrl+C button', () => {
      expect(html).not.toContain('sessionCtrlCBtn');
    });

    it('does not contain Ctrl+Z button', () => {
      expect(html).not.toContain('sessionCtrlZBtn');
    });

    it('does not contain ctrl-row', () => {
      expect(html).not.toContain('ctrl-row');
    });

    it('does not contain Record button', () => {
      expect(html).not.toContain('sessionRecordStartBtn');
    });

    it('does not contain rec-row', () => {
      expect(html).not.toContain('rec-row');
    });
  });
});
