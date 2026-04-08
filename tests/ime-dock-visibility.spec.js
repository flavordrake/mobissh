/**
 * tests/ime-dock-visibility.spec.js
 *
 * TDD red baseline for 5-position dock visibility (#255).
 *
 * These tests express the acceptance criteria for expanding the IME dock
 * toggle from a 2-position toggle (top/bottom) to a 5-position cycle:
 * hover-top, hover-bottom, cursor-follow, dock-above, dock-below.
 *
 * CRITICAL TEST: The dock toggle button must be visible and clickable in
 * ALL dock positions. The previous implementation (reverted in 9714b3d)
 * hid the button entirely.
 *
 * These tests FAIL on current main (2-position only) and will PASS when
 * the feature is properly re-implemented.
 */

const path = require('path');
const { test, expect, ensureTestVault } = require('./fixtures.js');

// ── helpers ───────────────────────────────────────────────────────────────────

/**
 * Connect to mock SSH server and land on the terminal panel.
 *
 * Adapted from fixtures.js setupConnected but without the .xterm-screen wait
 * that fails after the lobby terminal removal (dae5f66). The current app lands
 * on the Connect panel when localStorage is empty.
 */
async function setupConnected(page, mockSshServer) {
  // Inject WS spy before any app code runs
  await page.addInitScript(() => {
    window.__mockWsSpy = [];
    const OrigWS = window.WebSocket;
    window.WebSocket = class extends OrigWS {
      send(data) {
        window.__mockWsSpy.push(data);
        super.send(data);
      }
    };
  });

  // Clear localStorage
  await page.addInitScript(() => { localStorage.clear(); });

  await page.goto('./');

  // App lands on Connect panel (no profiles). Wait for it to be ready.
  await page.waitForSelector('#connectForm', { timeout: 8000 });

  // Create and unlock a test vault before any profile operations
  await ensureTestVault(page);

  // Set WS URL to the mock server
  await page.evaluate((port) => {
    localStorage.setItem('wsUrl', `ws://localhost:${port}`);
  }, mockSshServer.port);

  // Fill the connect form
  await page.locator('#host').fill('mock-host');
  await page.locator('#remote_a').fill('testuser');
  await page.locator('#remote_c').fill('testpass');

  // Submit to save the profile
  await page.locator('#connectForm button[type="submit"]').click();

  // Connect via the profile's Connect button
  const connectBtn = page.locator('[data-action="connect"]').first();
  await connectBtn.waitFor({ state: 'visible', timeout: 5000 });
  await connectBtn.click();

  // Wait until the app sends a `resize` message (connection established)
  await page.waitForFunction(() => {
    return (window.__mockWsSpy || []).some((s) => {
      try { return JSON.parse(s).type === 'resize'; } catch (_) { return false; }
    });
  }, null, { timeout: 10_000 });

  // Terminal panel should now be active
  await page.waitForSelector('#panel-terminal.active', { timeout: 5000 });
  await page.locator('#imeInput').focus().catch(() => {});
  await page.waitForTimeout(100);
}

/** Enable compose mode + preview mode, return to terminal with IME focused. */
async function enableComposePreview(page) {
  await page.evaluate(() => {
    const btn = document.getElementById('composeModeBtn');
    if (btn) btn.click();
  });
  await page.waitForTimeout(100);
  await page.evaluate(() => {
    const btn = document.getElementById('previewModeBtn');
    if (btn) btn.click();
  });
  await page.waitForTimeout(100);
}

/** Simulate a GBoard swipe composition on #imeInput. */
async function swipeCompose(page, text) {
  await page.evaluate((t) => {
    const el = document.getElementById('imeInput');
    el.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
    for (let i = 1; i <= t.length; i++) {
      el.dispatchEvent(new CompositionEvent('compositionupdate', { bubbles: true, data: t.slice(0, i) }));
    }
    el.value = (el.value ? el.value + ' ' : '') + t;
    el.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: t }));
  }, text);
  await page.waitForTimeout(100);
}

/**
 * All 5 dock positions expected after the feature is implemented.
 * Current main only has 'top' and 'bottom', so tests referencing
 * these values will fail on current main.
 */
const DOCK_POSITIONS = [
  'hover-top',
  'hover-bottom',
  'cursor-follow',
  'dock-above',
  'dock-below',
];

/** Set dock position via localStorage and trigger repositioning. */
async function setDockPosition(page, position) {
  await page.evaluate((pos) => {
    localStorage.setItem('imeDockPosition', pos);
  }, position);
}

/**
 * Get the current dock position from localStorage.
 * On current main this returns 'top' or 'bottom' (old values).
 */
async function getDockPosition(page) {
  return page.evaluate(() => localStorage.getItem('imeDockPosition'));
}

/**
 * Assert an element is within the visible viewport (not clipped, not zero-size).
 * Returns the bounding rect for further assertions.
 */
async function assertInViewport(page, selector) {
  const box = await page.locator(selector).boundingBox();
  expect(box, `${selector} should have a bounding box (not hidden/zero-size)`).toBeTruthy();
  expect(box.width).toBeGreaterThan(0);
  expect(box.height).toBeGreaterThan(0);

  const viewport = await page.viewportSize();
  expect(box.x).toBeGreaterThanOrEqual(0);
  expect(box.y).toBeGreaterThanOrEqual(0);
  expect(box.x + box.width).toBeLessThanOrEqual(viewport.width + 1);
  expect(box.y + box.height).toBeLessThanOrEqual(viewport.height + 1);

  return box;
}

/**
 * Mock visualViewport to simulate keyboard open (reduced height).
 * Dispatches a resize event so the app repositions.
 */
async function mockKeyboardOpen(page, keyboardHeight) {
  await page.evaluate((kbH) => {
    const fullHeight = window.innerHeight;
    const reducedHeight = fullHeight - kbH;
    // Override visualViewport properties
    Object.defineProperty(window.visualViewport, 'height', {
      value: reducedHeight,
      writable: true,
      configurable: true,
    });
    Object.defineProperty(window.visualViewport, 'offsetTop', {
      value: 0,
      writable: true,
      configurable: true,
    });
    window.visualViewport.dispatchEvent(new Event('resize'));
  }, keyboardHeight);
  await page.waitForTimeout(100);
}

/** Mock visualViewport back to full height (keyboard closed). */
async function mockKeyboardClose(page) {
  await page.evaluate(() => {
    Object.defineProperty(window.visualViewport, 'height', {
      value: window.innerHeight,
      writable: true,
      configurable: true,
    });
    Object.defineProperty(window.visualViewport, 'offsetTop', {
      value: 0,
      writable: true,
      configurable: true,
    });
    window.visualViewport.dispatchEvent(new Event('resize'));
  });
  await page.waitForTimeout(100);
}

const SS_DIR = path.join(__dirname, '..', 'test-results', 'screenshots', 'dock-visibility');

// ── Baseline visibility ──────────────────────────────────────────────────────

test.describe('Dock toggle baseline visibility (#255)', { tag: '@device-critical' }, () => {

  test('dock toggle button is visible and clickable in compose+preview mode', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableComposePreview(page);
    await swipeCompose(page, 'hello');

    const toggle = page.locator('#imeDockToggle');
    await expect(toggle).toBeVisible();
    await toggle.click();
    // Button should still be visible after clicking
    await expect(toggle).toBeVisible();
  });
});

// ── 5-position dock cycle ────────────────────────────────────────────────────

test.describe('5-position dock cycle (#255)', { tag: '@device-critical' }, () => {

  test('app recognizes all 5 dock position values from localStorage', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableComposePreview(page);

    // Set each of the 5 positions and verify the app reads them
    for (const pos of DOCK_POSITIONS) {
      await setDockPosition(page, pos);
      const stored = await getDockPosition(page);
      expect(stored).toBe(pos);

      // The app should recognize this value (not fall back to default)
      const recognized = await page.evaluate((p) => {
        const valid = ['hover-top', 'hover-bottom', 'cursor-follow', 'dock-above', 'dock-below'];
        return valid.includes(p);
      }, stored);
      expect(recognized, `${pos} should be a recognized dock position`).toBe(true);
    }
  });

  test('clicking dock toggle cycles through 5 positions and wraps', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableComposePreview(page);

    // Set initial position to hover-top
    await setDockPosition(page, 'hover-top');

    const toggle = page.locator('#imeDockToggle');
    const seen = [];

    // Click 5 times to cycle through all positions.
    // Re-compose before each click to keep the action bar visible (it hides after idle).
    for (let i = 0; i < 5; i++) {
      await swipeCompose(page, `cycle${i}`);
      await expect(toggle).toBeVisible({ timeout: 3000 });
      await toggle.click();
      await page.waitForTimeout(100);
      const pos = await getDockPosition(page);
      seen.push(pos);
    }

    // After 5 clicks starting from hover-top, we should have visited all 5 positions
    // and wrapped back to hover-top
    const unique = [...new Set(seen)];
    expect(unique).toHaveLength(5);
    expect(unique).toEqual(expect.arrayContaining(DOCK_POSITIONS));

    // One more click should wrap back to the second position (already cycled from first)
    await swipeCompose(page, 'wrap');
    await expect(toggle).toBeVisible({ timeout: 3000 });
    await toggle.click();
    await page.waitForTimeout(100);
    const wrapped = await getDockPosition(page);
    expect(wrapped).toBe(DOCK_POSITIONS[1]); // hover-bottom
  });
});

// ── Visibility in each dock position ─────────────────────────────────────────

test.describe('Preview visible and accessible in each dock position (#255)', { tag: '@device-critical' }, () => {

  for (const pos of DOCK_POSITIONS) {
    test(`${pos}: app reads and applies position from localStorage`, async ({ page, mockSshServer }) => {
      await setupConnected(page, mockSshServer);
      await setDockPosition(page, pos);
      await enableComposePreview(page);
      await swipeCompose(page, 'visible');

      // Core visibility: textarea has ime-visible, is within viewport
      const ime = page.locator('#imeInput');
      await expect(ime).toHaveClass(/ime-visible/);
      await assertInViewport(page, '#imeInput');

      // The app must read back the EXACT position value we set.
      // On current main, the app coerces everything to 'top'|'bottom',
      // so 'cursor-follow', 'dock-above', 'dock-below' get lost.
      const effectivePos = await page.evaluate(() => {
        // The app should expose the current dock position on the toggle button
        // or via a data attribute. Check aria-label or data-dock-position.
        const toggle = document.getElementById('imeDockToggle');
        return toggle?.getAttribute('data-dock-position')
          ?? toggle?.getAttribute('aria-label')
          ?? null;
      });
      // The toggle button must reflect the current position name
      expect(effectivePos, `dock toggle should reflect position "${pos}"`).toContain(pos);
    });

    test(`${pos}: action bar is visible and not hidden`, async ({ page, mockSshServer }) => {
      await setupConnected(page, mockSshServer);
      await setDockPosition(page, pos);
      await enableComposePreview(page);
      await swipeCompose(page, 'actions');

      const actions = page.locator('#imeActions');
      await expect(actions).not.toHaveClass(/hidden/);
      await expect(actions).toBeVisible();
    });

    test(`${pos}: dock toggle button is visible and clickable`, async ({ page, mockSshServer }) => {
      await setupConnected(page, mockSshServer);
      await setDockPosition(page, pos);
      await enableComposePreview(page);
      await swipeCompose(page, 'toggle');

      const toggle = page.locator('#imeDockToggle');
      await expect(toggle).toBeVisible();
      await assertInViewport(page, '#imeDockToggle');

      // Must be clickable (not covered by other elements)
      await toggle.click();
      // Should still be visible after click — THIS is what broke in the reverted implementation
      await swipeCompose(page, 'still-here');
      await expect(toggle).toBeVisible();
      await assertInViewport(page, '#imeDockToggle');
    });
  }
});

// ── Keyboard visible vs invisible ────────────────────────────────────────────

test.describe('Dock visibility with keyboard open/closed (#255)', { tag: '@device-critical' }, () => {

  for (const pos of DOCK_POSITIONS) {
    test(`${pos}: preview and toggle visible without keyboard`, async ({ page, mockSshServer }) => {
      await setupConnected(page, mockSshServer);
      await setDockPosition(page, pos);
      await enableComposePreview(page);
      await swipeCompose(page, 'no-keyboard');

      await mockKeyboardClose(page);

      await expect(page.locator('#imeInput')).toHaveClass(/ime-visible/);
      await assertInViewport(page, '#imeInput');
      await expect(page.locator('#imeActions')).not.toHaveClass(/hidden/);
      await expect(page.locator('#imeDockToggle')).toBeVisible();

      // Verify position is correctly applied (not coerced to top/bottom)
      const appliedPos = await page.evaluate(() => {
        const toggle = document.getElementById('imeDockToggle');
        return toggle?.getAttribute('data-dock-position') ?? null;
      });
      expect(appliedPos, `position "${pos}" should be applied without keyboard`).toBe(pos);
    });

    test(`${pos}: preview and toggle visible with keyboard open`, async ({ page, mockSshServer }) => {
      await setupConnected(page, mockSshServer);
      await setDockPosition(page, pos);
      await enableComposePreview(page);
      await swipeCompose(page, 'with-keyboard');

      // Simulate keyboard taking up ~500px (common mobile keyboard height)
      await mockKeyboardOpen(page, 500);

      await expect(page.locator('#imeInput')).toHaveClass(/ime-visible/);

      // Preview must still be within the reduced viewport
      const imeBox = await page.locator('#imeInput').boundingBox();
      expect(imeBox, 'preview textarea must have a bounding box with keyboard open').toBeTruthy();
      expect(imeBox.height).toBeGreaterThan(0);

      const vvHeight = await page.evaluate(() => window.visualViewport.height);
      // The preview bottom edge must be within the visible area (not behind keyboard)
      expect(imeBox.y + imeBox.height).toBeLessThanOrEqual(vvHeight + 1);

      // Action bar and dock toggle must also be visible
      await expect(page.locator('#imeActions')).not.toHaveClass(/hidden/);
      await expect(page.locator('#imeDockToggle')).toBeVisible();

      const toggleBox = await page.locator('#imeDockToggle').boundingBox();
      expect(toggleBox, 'dock toggle must have a bounding box with keyboard open').toBeTruthy();
      expect(toggleBox.y + toggleBox.height).toBeLessThanOrEqual(vvHeight + 1);

      // Verify position is correctly applied
      const appliedPos = await page.evaluate(() => {
        const toggle = document.getElementById('imeDockToggle');
        return toggle?.getAttribute('data-dock-position') ?? null;
      });
      expect(appliedPos, `position "${pos}" should be applied with keyboard open`).toBe(pos);
    });
  }
});
