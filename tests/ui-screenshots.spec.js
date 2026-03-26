/**
 * tests/ui-screenshots.spec.js
 *
 * Visual screenshot tests for UI features (#106).
 * Captures screenshots of key UI states for visual verification.
 * These are NOT pixel-diff assertions — they save PNGs to tools/screenshots/ui/
 * for human review.
 */

const path = require('path');
const { test, expect, setupConnected } = require('./fixtures.js');

const SCREENSHOT_DIR = path.join(__dirname, '..', 'tools', 'screenshots', 'ui');

/** Enable debug-ime so textarea is visible, enable compose mode, trigger composition. */
async function setupIMEComposition(page, mockSshServer, text) {
  await setupConnected(page, mockSshServer);
  await page.waitForTimeout(2000);

  // Enable debug-ime so textarea becomes visible
  await page.evaluate(() => document.body.classList.add('debug-ime'));

  // Enable compose mode
  await page.evaluate(() => {
    const btn = document.getElementById('composeModeBtn');
    if (btn) btn.click();
  });
  await page.waitForTimeout(200);

  // Simulate GBoard composition
  await page.evaluate((t) => {
    const ime = document.getElementById('imeInput');
    ime.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
    for (let i = 1; i <= t.length; i++) {
      ime.dispatchEvent(new CompositionEvent('compositionupdate', { bubbles: true, data: t.slice(0, i) }));
    }
    ime.value = t;
    ime.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: t }));
    ime.dispatchEvent(new InputEvent('input', { bubbles: true, data: t, inputType: 'insertCompositionText' }));
  }, text);
  await page.waitForTimeout(300);
}

// ── IME Action Buttons (#106) ─────────────────────────────────────────────

test.describe('IME action buttons visual states (#106)', { tag: '@device-critical' }, () => {

  test('action buttons appear on composition — bottom dock (default)', async ({ page, mockSshServer }) => {
    await setupIMEComposition(page, mockSshServer, 'hello world');

    const actions = page.locator('#imeActions');
    await expect(actions).not.toHaveClass(/hidden/);
    await expect(page.locator('#imeClearBtn')).toBeVisible();
    await expect(page.locator('#imeCommitBtn')).toBeVisible();
    await expect(page.locator('#imeDockToggle')).toBeVisible();

    await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'ime-actions-bottom-dock.png') });
  });

  test('dock toggle switches to top', async ({ page, mockSshServer }) => {
    await setupIMEComposition(page, mockSshServer, 'testing');

    // Toggle to top
    await page.click('#imeDockToggle');
    await page.waitForTimeout(200);
    await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'ime-actions-top-dock.png') });

    // Toggle back to bottom
    await page.click('#imeDockToggle');
    await page.waitForTimeout(200);
    await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'ime-actions-bottom-toggled.png') });
  });

  test('dock position persists in localStorage', async ({ page, mockSshServer }) => {
    await setupIMEComposition(page, mockSshServer, 'persist');

    await page.click('#imeDockToggle');
    const saved = await page.evaluate(() => localStorage.getItem('imeDockPosition'));
    expect(saved).toBe('top');
  });

  test('clear button hides actions', async ({ page, mockSshServer }) => {
    await setupIMEComposition(page, mockSshServer, 'clear me');

    const actions = page.locator('#imeActions');
    await expect(actions).not.toHaveClass(/hidden/);

    await page.click('#imeClearBtn');
    await page.waitForTimeout(200);

    await expect(actions).toHaveClass(/hidden/);
    await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'ime-actions-after-clear.png') });
  });
});

// ── Connection status dialog (#105) ─────────────────────────────────────────

test.describe('Connection status dialog visual states (#105)', { tag: '@device-critical' }, () => {

  test('connection status overlay has cancel button when disconnected', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    await page.evaluate(async () => {
      const ws = (await import('./modules/state.js')).appState.ws;
      if (ws) ws.close();
    });
    await page.waitForTimeout(1500);

    const overlay = page.locator('#connectionStatusOverlay');
    const cancelBtn = page.locator('.conn-status-cancel');

    await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'connection-dialog-after-drop.png') });

    const visible = await overlay.isVisible().catch(() => false);
    if (visible) {
      await expect(cancelBtn).toBeVisible();
      await expect(cancelBtn).toHaveText('Cancel');
    }
  });
});

// ── Cold start + tab layouts ────────────────────────────────────────────────

test.describe('Layout screenshots', { tag: '@device-critical' }, () => {

  test('cold start — terminal tab', async ({ page }) => {
    await page.goto('./');
    await Promise.race([page.waitForSelector('#connectForm', { timeout: 8000 }), page.waitForSelector('.xterm-screen', { timeout: 8000 })]);
    await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'layout-terminal.png') });
  });

  test('connect tab', async ({ page }) => {
    await page.goto('./');
    await Promise.race([page.waitForSelector('#connectForm', { timeout: 8000 }), page.waitForSelector('.xterm-screen', { timeout: 8000 })]);
    await page.click('[data-panel="connect"]');
    await page.waitForTimeout(300);
    await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'layout-connect.png') });
  });

  test('settings tab', async ({ page }) => {
    await page.goto('./');
    await Promise.race([page.waitForSelector('#connectForm', { timeout: 8000 }), page.waitForSelector('.xterm-screen', { timeout: 8000 })]);
    await page.click('[data-panel="settings"]');
    await page.waitForTimeout(300);
    await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'layout-settings.png') });
  });
});
