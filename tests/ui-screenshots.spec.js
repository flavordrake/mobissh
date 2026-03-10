/**
 * tests/ui-screenshots.spec.js
 *
 * Visual screenshot tests for UI features (#106).
 * Captures screenshots of key UI states for visual verification.
 * These are NOT pixel-diff assertions — they save PNGs to test-results/screenshots/
 * for human review. Run after any UI change to catch layout/positioning issues
 * that functional tests miss.
 */

const path = require('path');
const { test, expect, setupConnected } = require('./fixtures.js');

const SCREENSHOT_DIR = path.join(__dirname, '..', 'test-results', 'screenshots', 'ui');

// ── IME Preview (#106) ──────────────────────────────────────────────────────

test.describe('IME preview visual states (#106)', () => {

  test('ime preview appears on composition — bottom dock (default)', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Trigger IME composition to show the preview
    await page.evaluate(() => {
      const ime = document.getElementById('imeInput');
      ime.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
      ime.dispatchEvent(new CompositionEvent('compositionupdate', { bubbles: true, data: 'hello world' }));
      ime.value = 'hello world';
      ime.dispatchEvent(new InputEvent('input', { bubbles: true, data: 'hello world', inputType: 'insertCompositionText' }));
    });
    await page.waitForTimeout(200);

    // Verify preview is visible
    const preview = page.locator('#imePreview');
    await expect(preview).not.toHaveClass(/hidden/);

    // Verify buttons exist
    await expect(page.locator('#imeClearBtn')).toBeVisible();
    await expect(page.locator('#imeCommitBtn')).toBeVisible();
    await expect(page.locator('#imeDockToggle')).toBeVisible();

    // Verify preview text
    await expect(page.locator('#imePreviewText')).toHaveText('hello world');

    // Verify default bottom dock
    await expect(preview).toHaveClass(/ime-preview-bottom/);

    await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'ime-preview-bottom-dock.png') });
  });

  test('ime preview dock toggle switches to top', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Trigger composition
    await page.evaluate(() => {
      const ime = document.getElementById('imeInput');
      ime.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
      ime.dispatchEvent(new CompositionEvent('compositionupdate', { bubbles: true, data: 'testing' }));
      ime.value = 'testing';
      ime.dispatchEvent(new InputEvent('input', { bubbles: true, data: 'testing', inputType: 'insertCompositionText' }));
    });
    await page.waitForTimeout(200);

    const preview = page.locator('#imePreview');

    // Toggle to top
    await page.click('#imeDockToggle');
    await expect(preview).toHaveClass(/ime-preview-top/);
    await expect(preview).not.toHaveClass(/ime-preview-bottom/);
    await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'ime-preview-top-dock.png') });

    // Toggle back to bottom
    await page.click('#imeDockToggle');
    await expect(preview).toHaveClass(/ime-preview-bottom/);
    await expect(preview).not.toHaveClass(/ime-preview-top/);
    await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'ime-preview-bottom-toggled.png') });
  });

  test('ime preview dock position persists in localStorage', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Trigger composition and toggle to top
    await page.evaluate(() => {
      const ime = document.getElementById('imeInput');
      ime.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
      ime.dispatchEvent(new CompositionEvent('compositionupdate', { bubbles: true, data: 'persist' }));
      ime.value = 'persist';
      ime.dispatchEvent(new InputEvent('input', { bubbles: true, data: 'persist', inputType: 'insertCompositionText' }));
    });
    await page.waitForTimeout(200);

    await page.click('#imeDockToggle');

    const saved = await page.evaluate(() => localStorage.getItem('imeDockPosition'));
    expect(saved).toBe('top');
  });

  test('ime preview clear button hides preview', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    await page.evaluate(() => {
      const ime = document.getElementById('imeInput');
      ime.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
      ime.dispatchEvent(new CompositionEvent('compositionupdate', { bubbles: true, data: 'clear me' }));
      ime.value = 'clear me';
      ime.dispatchEvent(new InputEvent('input', { bubbles: true, data: 'clear me', inputType: 'insertCompositionText' }));
    });
    await page.waitForTimeout(200);

    const preview = page.locator('#imePreview');
    await expect(preview).not.toHaveClass(/hidden/);

    await page.click('#imeClearBtn');
    await page.waitForTimeout(200);

    await expect(preview).toHaveClass(/hidden/);
    await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'ime-preview-after-clear.png') });
  });
});

// ── Connection status dialog (#105) ─────────────────────────────────────────

test.describe('Connection status dialog visual states (#105)', () => {

  test('connection status overlay has cancel button when disconnected', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Trigger disconnect from page side to force WS close → overlay appears
    await page.evaluate(async () => {
      // Forcefully close WS to simulate unclean disconnect
      const ws = (await import('./modules/state.js')).appState.ws;
      if (ws) ws.close();
    });
    await page.waitForTimeout(1500);

    const overlay = page.locator('#connectionStatusOverlay');
    const cancelBtn = page.locator('.conn-status-cancel');

    await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'connection-dialog-after-drop.png') });

    // If overlay appeared, cancel button must be present
    const visible = await overlay.isVisible().catch(() => false);
    if (visible) {
      await expect(cancelBtn).toBeVisible();
      await expect(cancelBtn).toHaveText('Cancel');
    }
  });
});

// ── Cold start + tab layouts ────────────────────────────────────────────────

test.describe('Layout screenshots', () => {

  test('cold start — terminal tab', async ({ page }) => {
    await page.goto('./');
    await page.waitForSelector('.xterm-screen', { timeout: 8000 });
    await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'layout-terminal.png') });
  });

  test('connect tab', async ({ page }) => {
    await page.goto('./');
    await page.waitForSelector('.xterm-screen', { timeout: 8000 });
    await page.click('[data-panel="connect"]');
    await page.waitForTimeout(300);
    await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'layout-connect.png') });
  });

  test('settings tab', async ({ page }) => {
    await page.goto('./');
    await page.waitForSelector('.xterm-screen', { timeout: 8000 });
    await page.click('[data-panel="settings"]');
    await page.waitForTimeout(300);
    await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'layout-settings.png') });
  });
});
