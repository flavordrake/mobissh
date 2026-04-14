/**
 * Tests for navbar simplification (#449).
 *
 * Verifies:
 *  - Navbar has exactly 3 tabs (Terminal, Connect, Settings), no Files tab.
 *  - Hamburger (#handleMenuBtn) opens #sessionMenu instead of toggling tabBar.
 *  - Up-swipe on #key-bar-handle reveals the navbar when it is hidden.
 *  - Down-swipe on #tabBar hides it.
 *  - #sessionFilesBtn is still present in the session menu (regression guard for #409).
 *
 * Uses source-file string inspection (see session-menu-slim.test.ts for pattern).
 */
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const html = readFileSync(resolve(__dirname, '../../../public/index.html'), 'utf-8');
const uiSrc = readFileSync(resolve(__dirname, '../ui.ts'), 'utf-8');

/** Extract the <nav id="tabBar">…</nav> block from index.html. */
function extractTabBar(src: string): string {
  const start = src.indexOf('<nav id="tabBar">');
  expect(start).toBeGreaterThan(-1);
  const end = src.indexOf('</nav>', start);
  expect(end).toBeGreaterThan(start);
  return src.slice(start, end + '</nav>'.length);
}

describe('navbar simplification (#449)', () => {
  describe('tabBar markup', () => {
    const tabBar = extractTabBar(html);

    it('contains exactly 3 tab buttons', () => {
      const matches = tabBar.match(/class="tab[^"]*"\s+data-panel=/g) ?? [];
      expect(matches.length).toBe(3);
    });

    it('does not contain a Files tab (data-panel="files")', () => {
      expect(tabBar).not.toMatch(/data-panel="files"/);
    });

    it('contains the Terminal tab', () => {
      expect(tabBar).toMatch(/data-panel="terminal"/);
    });

    it('contains the Connect tab', () => {
      expect(tabBar).toMatch(/data-panel="connect"/);
    });

    it('contains the Settings tab', () => {
      expect(tabBar).toMatch(/data-panel="settings"/);
    });
  });

  describe('hamburger opens session menu', () => {
    it('handleMenuBtn click handler opens the session menu (no longer calls toggleTabBar)', () => {
      // Locate the handleMenuBtn click handler block.
      const handlerStart = uiSrc.indexOf("getElementById('handleMenuBtn')");
      expect(handlerStart).toBeGreaterThan(-1);

      // The handler body is within the next ~600 chars.
      const handlerBlock = uiSrc.slice(handlerStart, handlerStart + 600);

      // New behavior: handler toggles the 'hidden' class on the menu element.
      // The handler works with the closed-over `menu` / `backdrop` variables
      // from initSessionMenu, so we verify menu toggling rather than the id string.
      expect(handlerBlock).toMatch(/menu\.classList\.toggle\(['"]hidden['"]/);

      // Old behavior removed: handler no longer calls toggleTabBar().
      expect(handlerBlock).not.toMatch(/toggleTabBar\s*\(/);
    });
  });

  describe('swipe gestures on navbar', () => {
    it('an upward swipe on key-bar-handle reveals the navbar when hidden', () => {
      // The handle's touchend handler must include a branch that makes the tabBar
      // visible when an upward swipe is detected. We verify the ui.ts source
      // contains a path where tabBarVisible is set to true (revealing the navbar)
      // and that it sits near the handle's touchend listener.
      expect(uiSrc).toMatch(/tabBarVisible\s*=\s*true/);

      // And that the revealing happens in the same lexical neighborhood as the
      // key-bar-handle touchend handler (i.e. swipe-driven).
      const handleSwipeStart = uiSrc.indexOf("const handle = document.getElementById('key-bar-handle')");
      expect(handleSwipeStart).toBeGreaterThan(-1);
      const handleSwipeBlock = uiSrc.slice(handleSwipeStart, handleSwipeStart + 2500);
      expect(handleSwipeBlock).toMatch(/tabBarVisible\s*=\s*true/);
    });

    it('tabBar has a downward-swipe handler that hides it', () => {
      // A touch listener must be registered on the #tabBar element itself,
      // and it must set tabBarVisible to false.
      expect(uiSrc).toMatch(/const\s+tabBarEl\s*=\s*document\.getElementById\(['"]tabBar['"]\)/);
      expect(uiSrc).toMatch(/tabBarEl\.addEventListener\(\s*['"]touch/);
      expect(uiSrc).toMatch(/tabBarVisible\s*=\s*false/);
    });
  });

  describe('regression guards', () => {
    it('#sessionFilesBtn is still present in markup (#409)', () => {
      expect(html).toContain('id="sessionFilesBtn"');
    });

    it('session menu Files button still calls navigateToPanel(\'files\')', () => {
      // Verify the existing #409 wiring hasn't been lost.
      const filesBtnHandler = uiSrc.indexOf("getElementById('sessionFilesBtn')");
      expect(filesBtnHandler).toBeGreaterThan(-1);
      const block = uiSrc.slice(filesBtnHandler, filesBtnHandler + 400);
      expect(block).toMatch(/navigateToPanel\(['"]files['"]/);
    });

    it('MobiSSH #sessionMenuBtn still exists as an alternate menu entry', () => {
      // The MobiSSH button should remain a menu opener.
      expect(html).toContain('id="sessionMenuBtn"');
    });
  });
});
