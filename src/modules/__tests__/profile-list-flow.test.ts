/**
 * Profile list flows as a grid on wider viewports.
 *
 * User feedback: "we lay out on tablet profile cards should be narrower and
 * flow instead of stacked, anywhere. we have the space including PC. use a
 * reasonable width. we still want them to be visible and they should flow
 * naturally as font sizes increase."
 *
 * Implementation contract enforced by these tests:
 *
 * 1. `.item-list` uses CSS grid with auto-fill and minmax — that's the
 *    primitive that gives natural flow at any container width.
 * 2. The minimum column width is expressed in `ch` units so the layout
 *    breakpoint scales with the user's chosen font size (per the
 *    "flow naturally as font sizes increase" requirement).
 * 3. The minimum is 24-36ch — wide enough that "host:port" + "username"
 *    are readable, narrow enough to flow 2-3+ columns on a tablet.
 */
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const css = readFileSync(resolve(__dirname, '../../../public/app.css'), 'utf-8');

function selectorBlock(selector: string): string | null {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\#]/g, '\\$&');
  const re = new RegExp(`${escaped}\\s*\\{([^}]*)\\}`, 's');
  const m = css.match(re);
  return m ? m[1] : null;
}

describe('.item-list flow layout', () => {
  it('uses display: grid (not flex column) so cards flow', () => {
    const block = selectorBlock('.item-list');
    expect(block, '.item-list block not found in app.css').toBeTruthy();
    expect(block).toMatch(/display:\s*grid/);
  });

  it('uses grid-template-columns with repeat(auto-fill, minmax(...))', () => {
    const block = selectorBlock('.item-list');
    expect(block).toMatch(/grid-template-columns:\s*repeat\s*\(\s*auto-fill\s*,\s*minmax\s*\(/);
  });

  it('minimum column width is in ch units (scales with font size)', () => {
    const block = selectorBlock('.item-list');
    // The minmax should look like minmax(28ch, 1fr) — ch is the key unit so
    // increasing font-size widens cards proportionally and reduces column
    // count gracefully.
    expect(block).toMatch(/minmax\s*\(\s*\d+ch\s*,\s*1fr\s*\)/);
  });

  it('minimum is in the readable range 24-36ch', () => {
    const block = selectorBlock('.item-list')!;
    const m = block.match(/minmax\s*\(\s*(\d+)ch\s*,/);
    expect(m, 'minmax not found in .item-list').toBeTruthy();
    const minCh = parseInt(m![1]!, 10);
    expect(minCh).toBeGreaterThanOrEqual(24);
    expect(minCh).toBeLessThanOrEqual(36);
  });

  it('keeps a sensible gap between cards', () => {
    const block = selectorBlock('.item-list');
    expect(block).toMatch(/gap:\s*\d+px/);
  });
});

describe('profile-item card sizing in flow', () => {
  it('does not have a fixed width that would block grid sizing', () => {
    const block = selectorBlock('.profile-item, .key-item');
    expect(block).toBeTruthy();
    // No `width: ...px` or `width: 100%` — the grid track width governs.
    expect(block).not.toMatch(/^\s*width:/m);
  });
});
