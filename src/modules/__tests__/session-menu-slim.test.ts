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

  describe('key bar has Ctrl+C and Ctrl+Z in row-keys (#250 moved from row-nav)', () => {
    it('row-keys contains keyCtrlC with correct sequence', () => {
      const row = DEFAULT_KEY_BAR_CONFIG.find((r) => r.id === 'row-keys');
      expect(row).toBeDefined();
      const ctrlC = row!.buttons.find((b) => b.id === 'keyCtrlC');
      expect(ctrlC).toBeDefined();
      expect(ctrlC!.sequence).toBe('\x03');
      expect(ctrlC!.label).toBe('^C');
    });

    it('row-keys contains keyCtrlZ with correct sequence', () => {
      const row = DEFAULT_KEY_BAR_CONFIG.find((r) => r.id === 'row-keys');
      expect(row).toBeDefined();
      const ctrlZ = row!.buttons.find((b) => b.id === 'keyCtrlZ');
      expect(ctrlZ).toBeDefined();
      expect(ctrlZ!.sequence).toBe('\x1a');
      expect(ctrlZ!.label).toBe('^Z');
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

  describe('session menu CSS', () => {
    const css = readFileSync(resolve(__dirname, '../../../public/app.css'), 'utf-8');

    it('has narrower max-width (220px or less)', () => {
      const match = css.match(/#sessionMenu\s*\{[^}]*max-width:\s*min\((\d+)px/);
      expect(match).toBeTruthy();
      expect(Number(match![1])).toBeLessThanOrEqual(220);
    });

    it('does not contain dead .rec-row or .ctrl-row styles', () => {
      expect(css).not.toContain('.rec-row');
      expect(css).not.toContain('.ctrl-row');
      expect(css).not.toContain('.rec-btn');
      expect(css).not.toContain('.ctrl-btn');
    });

    it('animation keyframes preserve translateX(-50%) centering (#222)', () => {
      // The sessionMenuSlideUp animation must include translateX(-50%) in both
      // from and to keyframes, otherwise the animation overrides the centering
      // transform and causes a visible snap from right to center.
      // Extract the full keyframes block using a multiline match
      const keyframeStart = css.indexOf('@keyframes sessionMenuSlideUp');
      expect(keyframeStart).toBeGreaterThan(-1);
      // Find the closing brace of the @keyframes block (third '}' after start)
      let braceDepth = 0;
      let keyframeEnd = -1;
      for (let i = keyframeStart; i < css.length; i++) {
        if (css[i] === '{') braceDepth++;
        if (css[i] === '}') {
          braceDepth--;
          if (braceDepth === 0) { keyframeEnd = i + 1; break; }
        }
      }
      expect(keyframeEnd).toBeGreaterThan(keyframeStart);
      const keyframeBlock = css.slice(keyframeStart, keyframeEnd);

      // Extract from and to blocks
      const fromMatch = keyframeBlock.match(/from\s*\{([^}]*)\}/);
      const toMatch = keyframeBlock.match(/to\s*\{([^}]*)\}/);
      expect(fromMatch).toBeTruthy();
      expect(toMatch).toBeTruthy();
      // Both frames must include translateX(-50%) to maintain centering
      expect(fromMatch![1]).toContain('translateX(-50%)');
      expect(toMatch![1]).toContain('translateX(-50%)');
    });
  });
});
