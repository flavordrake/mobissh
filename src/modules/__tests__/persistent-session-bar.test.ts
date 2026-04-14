/**
 * TDD tests for persistent session bar across Terminal and Files panels (#452)
 *
 * The session handle strip (`#key-bar-handle`) and key bar (`#key-bar`) must
 * persist across session-level panels (Terminal, Files) and hide on app-level
 * panels (Connect, Settings). The old per-panel back-to-terminal button is
 * redundant and removed.
 */
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const indexHtml = readFileSync(resolve(__dirname, '../../../public/index.html'), 'utf8');
const uiSrc = readFileSync(resolve(__dirname, '../ui.ts'), 'utf8');
const appCss = readFileSync(resolve(__dirname, '../../../public/app.css'), 'utf8');

describe('persistent session bar (#452) — structural HTML', () => {
  // Approximate the DOM subtree of `#panel-terminal` using balanced-div scan.
  // `id="panel-terminal"` opens at a known index; we walk forward counting
  // `<div` vs `</div>` to find where it closes.
  function panelTerminalSpan(): { start: number; end: number } {
    const openAttr = indexHtml.indexOf('id="panel-terminal"');
    // Back up to the `<div` that bears this attribute.
    const start = indexHtml.lastIndexOf('<div', openAttr);
    let i = start;
    let depth = 0;
    const openRe = /<div\b/g;
    const closeRe = /<\/div>/g;
    while (i < indexHtml.length) {
      openRe.lastIndex = i;
      closeRe.lastIndex = i;
      const nextOpen = openRe.exec(indexHtml);
      const nextClose = closeRe.exec(indexHtml);
      if (!nextClose) break;
      if (nextOpen && nextOpen.index < nextClose.index) {
        depth += 1;
        i = nextOpen.index + 4;
      } else {
        depth -= 1;
        i = nextClose.index + 6;
        if (depth === 0) return { start, end: i };
      }
    }
    throw new Error('panel-terminal closing tag not found');
  }

  it('#key-bar-handle is NOT a descendant of #panel-terminal', () => {
    const { start, end } = panelTerminalSpan();
    const handleIdx = indexHtml.indexOf('id="key-bar-handle"');
    expect(handleIdx).toBeGreaterThan(-1);
    const insideTerminal = handleIdx > start && handleIdx < end;
    expect(insideTerminal).toBe(false);
  });

  it('#key-bar is NOT a descendant of #panel-terminal', () => {
    const { start, end } = panelTerminalSpan();
    const keyBarIdx = indexHtml.search(/id="key-bar"[^-]/);
    expect(keyBarIdx).toBeGreaterThan(-1);
    const insideTerminal = keyBarIdx > start && keyBarIdx < end;
    expect(insideTerminal).toBe(false);
  });

  it('#filesBackToTerminalBtn does NOT exist in the DOM', () => {
    expect(indexHtml).not.toContain('id="filesBackToTerminalBtn"');
  });

  it('ui.ts has no references to filesBackToTerminalBtn', () => {
    expect(uiSrc).not.toContain('filesBackToTerminalBtn');
  });
});

describe('persistent session bar (#452) — CSS visibility rules', () => {
  it('CSS has a body.session-chrome-hidden rule that hides the handle strip', () => {
    // The rule should hide at least `#key-bar-handle` when the body class is set.
    // Pattern: `body.session-chrome-hidden #key-bar-handle` or similar.
    expect(appCss).toMatch(
      /body\.session-chrome-hidden[^{]*#key-bar-handle/
    );
  });

  it('CSS has a body.session-chrome-hidden rule that hides the key-bar', () => {
    expect(appCss).toMatch(
      /body\.session-chrome-hidden[^{]*#key-bar\b/
    );
  });
});

describe('persistent session bar (#452) — navigateToPanel behavior', () => {
  it('ui.ts navigateToPanel toggles body.session-chrome-hidden class', () => {
    // The function must add/remove the class based on panel type.
    expect(uiSrc).toMatch(/session-chrome-hidden/);

    // And the toggle must happen inside navigateToPanel. Grab the function body.
    const navStart = uiSrc.indexOf('export function navigateToPanel');
    expect(navStart).toBeGreaterThan(-1);
    // Walk ~2500 chars of source to cover the function body.
    const navBlock = uiSrc.slice(navStart, navStart + 3000);
    expect(navBlock).toMatch(/session-chrome-hidden/);
  });
});
