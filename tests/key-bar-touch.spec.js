/**
 * tests/key-bar-touch.spec.js
 *
 * Regression tests for key-bar touch interactions that broke in a6b4a53.
 *
 * Context:
 *   a6b4a53 added `touchstart preventDefault` on `.key-btn` targets inside
 *   `#key-bar`. Intent: prevent keyboard dismiss on long-press. Actual effect:
 *     - Blocked the synthesized click → Ctrl toggle stopped working
 *     - Interfered with horizontal scroll of #key-scroll → couldn't pan keybar
 *
 *   913e06a reverted the preventDefault. These tests lock in that the keybar
 *   remains interactive and block that specific regression from returning.
 *
 *   Existing tests in tests/ui.spec.js already cover:
 *     - tabindex="-1" on key buttons
 *     - horizontal scroll CSS
 *     - tap sends key (#keyTab → '\t', #keyEscM2 → '\x1b')
 *     - no double-fire
 *
 *   This file adds:
 *     - Ctrl sticky modifier toggles on click
 *     - user-select:none on .key-btn (prevents long-press text selection)
 *     - touchstart on .key-btn does NOT call preventDefault (the specific regression)
 */

const { test, expect, setupConnected } = require('./fixtures.js');

test.describe('Key bar touch regression (#913e06a)', { tag: '@device-critical' }, () => {

  test('Ctrl button toggles the sticky modifier class on click', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Expand key bar so buttons are visible (depth-2 shows nav row too)
    await page.evaluate(() => {
      const bar = document.getElementById('key-bar');
      bar?.classList.remove('depth-0', 'depth-1');
      bar?.classList.add('depth-2');
    });

    const ctrl = page.locator('#keyCtrl');
    await expect(ctrl).toBeVisible();
    await expect(ctrl).not.toHaveClass(/active/);

    await ctrl.click();
    await expect(ctrl).toHaveClass(/active/);

    await ctrl.click();
    await expect(ctrl).not.toHaveClass(/active/);
  });

  test('key-btn has user-select:none to prevent long-press text selection', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await page.evaluate(() => {
      const bar = document.getElementById('key-bar');
      bar?.classList.remove('depth-0', 'depth-1');
      bar?.classList.add('depth-2');
    });

    const style = await page.locator('#keyCtrl').evaluate((el) => {
      const cs = getComputedStyle(el);
      return {
        userSelect: cs.userSelect,
        webkitUserSelect: cs.webkitUserSelect,
      };
    });
    // Either (or both) should be 'none' — spec and webkit prefix
    const anyNone = style.userSelect === 'none' || style.webkitUserSelect === 'none';
    expect(anyNone).toBe(true);
  });

  test('touchstart on a key button does NOT call preventDefault (regression guard)', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await page.evaluate(() => {
      const bar = document.getElementById('key-bar');
      bar?.classList.remove('depth-0', 'depth-1');
      bar?.classList.add('depth-2');
    });

    // Dispatch a cancelable touchstart via Playwright's dispatchEvent.
    // If any listener (on key-bar or document) calls preventDefault, the event's
    // defaultPrevented flag will be true — which was the regression in a6b4a53.
    const result = await page.locator('#keyCtrl').evaluate((el) => {
      // Build a plain Event (not TouchEvent) — some headless browsers lack
      // the Touch constructor. A plain cancelable Event with type 'touchstart'
      // still exercises the defaultPrevented pathway on any listener that
      // registered for the event name.
      const ev = new Event('touchstart', { bubbles: true, cancelable: true });
      el.dispatchEvent(ev);
      return ev.defaultPrevented;
    });
    expect(result).toBe(false);
  });

  test('#key-bar has no listener that prevents click on .key-btn via touchstart', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await page.evaluate(() => {
      const bar = document.getElementById('key-bar');
      bar?.classList.remove('depth-0', 'depth-1');
      bar?.classList.add('depth-2');
    });

    // After a touchstart+touchend sequence, a real click should still reach
    // the button's listener. Simulate by firing touchstart then click.
    const clicks = await page.locator('#keyCtrl').evaluate((el) => {
      let count = 0;
      const handler = () => { count++; };
      el.addEventListener('click', handler, true);
      const ts = new Event('touchstart', { bubbles: true, cancelable: true });
      el.dispatchEvent(ts);
      const te = new Event('touchend', { bubbles: true, cancelable: true });
      el.dispatchEvent(te);
      el.click(); // programmatic click (always fires — but this tests listener wiring)
      el.removeEventListener('click', handler, true);
      return { count, tsDefaultPrevented: ts.defaultPrevented };
    });
    expect(clicks.tsDefaultPrevented).toBe(false);
    expect(clicks.count).toBeGreaterThanOrEqual(1);
  });
});
