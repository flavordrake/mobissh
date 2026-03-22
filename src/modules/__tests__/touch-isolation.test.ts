import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const css = readFileSync(resolve(__dirname, '../../../public/app.css'), 'utf-8');

/**
 * Extract the declaration block for a given selector from the CSS source.
 * Returns the content between { and } (non-greedy) for the first match.
 */
function selectorBlock(selector: string): string | null {
  // Escape CSS special chars for regex
  const escaped = selector.replace(/[.*+?^${}()|[\]\\#]/g, '\\$&');
  const re = new RegExp(`${escaped}\\s*\\{([^}]*)\\}`, 's');
  const m = css.match(re);
  return m ? m[1] : null;
}

describe('touch isolation — scrollable overlay CSS (#268)', () => {
  const selectors = ['.notif-drawer-list', '#sessionMenu', '.debug-panel-log'];

  for (const sel of selectors) {
    describe(sel, () => {
      it('has touch-action: pan-y', () => {
        const block = selectorBlock(sel);
        expect(block, `${sel} block not found in app.css`).toBeTruthy();
        expect(block).toMatch(/touch-action:\s*pan-y/);
      });

      it('has overscroll-behavior: contain', () => {
        const block = selectorBlock(sel);
        expect(block, `${sel} block not found in app.css`).toBeTruthy();
        expect(block).toMatch(/overscroll-behavior:\s*contain/);
      });
    });
  }

  // Verify the existing pattern on .files-body is preserved
  describe('.files-body (existing pattern)', () => {
    it('retains touch-action: pan-y', () => {
      const block = selectorBlock('.files-body');
      expect(block).toBeTruthy();
      expect(block).toMatch(/touch-action:\s*pan-y/);
    });
  });
});

describe('keybar swipe guard — scrollable overlay check (#268)', () => {
  it('ui.ts touchstart handler references scrollable overlay selector', () => {
    const src = readFileSync(resolve(__dirname, '../ui.ts'), 'utf-8');
    // The handler should check target.closest() against scrollable overlay selectors
    expect(src).toContain('target.closest(_scrollableOverlay)');
    // The selector string should include sessionMenu, notif-drawer-list, debug-panel-log
    expect(src).toContain('#sessionMenu');
    expect(src).toContain('.notif-drawer-list');
    expect(src).toContain('.debug-panel-log');
  });
});
