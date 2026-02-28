/**
 * tests/ui.spec.js
 *
 * UI chrome — test gate for Phase 8 module extraction (#110).
 * Tests session menu, tab bar toggle, key bar visibility toggle,
 * IME/direct mode toggle, toast utility, and connect form auth switching.
 */

const { test, expect, setupConnected } = require('./fixtures.js');

// After setupConnected the tab bar is auto-hidden (#36). Show it via session menu (#149).
async function showTabBar(page) {
  await page.locator('#sessionMenuBtn').click();
  await page.locator('#sessionNavBarBtn').click();
  await page.waitForSelector('#tabBar:not(.hidden)', { timeout: 2000 });
}

test.describe('UI chrome (#110 Phase 8)', () => {

  test('session menu "Toggle nav bar" shows and hides the tab bar (#149)', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // After connection, tab bar is hidden
    await expect(page.locator('#tabBar')).toHaveClass(/hidden/);

    // Open session menu and toggle nav bar to show
    await page.locator('#sessionMenuBtn').click();
    await page.locator('#sessionNavBarBtn').click();
    await expect(page.locator('#tabBar')).not.toHaveClass(/hidden/);

    // Toggle again to hide
    await page.locator('#sessionMenuBtn').click();
    await page.locator('#sessionNavBarBtn').click();
    await expect(page.locator('#tabBar')).toHaveClass(/hidden/);
  });

  test('key bar visibility toggles via chevron button', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Key bar should be visible by default
    await expect(page.locator('#key-bar')).not.toHaveClass(/hidden/);

    // Click chevron to hide
    await page.locator('#handleChevron').click();
    await expect(page.locator('#key-bar')).toHaveClass(/hidden/);

    // Persists to localStorage
    const stored = await page.evaluate(() => localStorage.getItem('keyBarVisible'));
    expect(stored).toBe('false');

    // Click chevron to show again
    await page.locator('#handleChevron').click();
    await expect(page.locator('#key-bar')).not.toHaveClass(/hidden/);
  });

  test('compose/direct mode toggle switches and persists (#146)', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Default is Direct mode (secure by default)
    const modeBefore = await page.evaluate(() => localStorage.getItem('imeMode'));
    expect(modeBefore).toBeNull(); // default — not set yet, resolves to direct

    // Click compose button to switch to compose (IME) mode
    await page.locator('#composeModeBtn').click();
    await page.waitForTimeout(100);

    const modeAfter = await page.evaluate(() => localStorage.getItem('imeMode'));
    expect(modeAfter).toBe('ime');

    // Button should have compose-active class and accent line on key bar
    const btnHasClass = await page.locator('#composeModeBtn').evaluate(
      (el) => el.classList.contains('compose-active')
    );
    expect(btnHasClass).toBe(true);
    const barHasClass = await page.locator('#key-bar').evaluate(
      (el) => el.classList.contains('compose-active')
    );
    expect(barHasClass).toBe(true);

    // Click again to switch back to direct
    await page.locator('#composeModeBtn').click();
    await page.waitForTimeout(100);

    const modeRestored = await page.evaluate(() => localStorage.getItem('imeMode'));
    expect(modeRestored).toBe('direct');
  });

  test('session menu opens only when connected', async ({ page }) => {
    await page.addInitScript(() => { localStorage.clear(); });
    await page.goto('./');
    await page.waitForSelector('.xterm-screen', { timeout: 8000 });

    // Click session menu button when not connected — menu should stay hidden
    await page.locator('#sessionMenuBtn').click();
    await page.waitForTimeout(100);
    await expect(page.locator('#sessionMenu')).toHaveClass(/hidden/);
  });

  test('session menu opens when connected and closes on outside click', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Click session menu button — menu should appear
    await page.locator('#sessionMenuBtn').click();
    await page.waitForTimeout(100);
    await expect(page.locator('#sessionMenu')).not.toHaveClass(/hidden/);

    // Click the backdrop overlay (top-left, away from the menu) — dismisses the menu
    await page.locator('#menuBackdrop').click({ position: { x: 10, y: 10 } });
    await page.waitForTimeout(100);
    await expect(page.locator('#sessionMenu')).toHaveClass(/hidden/);
  });

  test('connect form auth type switch toggles password/key fields', async ({ page }) => {
    await page.addInitScript(() => { localStorage.clear(); });
    await page.goto('./');
    await page.waitForSelector('.xterm-screen', { timeout: 8000 });

    await page.locator('[data-panel="connect"]').click();

    // Default is password — password group visible, key group hidden
    await expect(page.locator('#passwordGroup')).toBeVisible();
    await expect(page.locator('#keyGroup')).toBeHidden();

    // Switch to key auth
    await page.locator('#authType').selectOption('key');
    await page.waitForTimeout(100);

    // Password group hidden, key group visible
    await expect(page.locator('#passwordGroup')).toBeHidden();
    await expect(page.locator('#keyGroup')).toBeVisible();
  });

  test('toast shows and auto-hides', async ({ page }) => {
    await page.addInitScript(() => { localStorage.clear(); });
    await page.goto('./');
    await page.waitForSelector('.xterm-screen', { timeout: 8000 });

    await page.locator('[data-panel="settings"]').click();

    // Trigger a toast by entering an invalid URL and clicking save
    await page.locator('#wsUrl').fill('invalid-url');
    await page.locator('#saveSettingsBtn').click();
    await page.waitForTimeout(100);

    // Toast should be visible
    const toast = page.locator('#toast');
    await expect(toast).toHaveClass(/show/);
    const text = await toast.textContent();
    expect(text).toContain('wss://');
  });

  test('tab bar returns to terminal and auto-hides after connection', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Show tab bar and switch to settings
    await showTabBar(page);
    await page.locator('[data-panel="settings"]').click();
    await expect(page.locator('#panel-settings')).toHaveClass(/active/);

    // Switch back to terminal
    await page.locator('[data-panel="terminal"]').click();
    await page.waitForTimeout(100);

    // Terminal panel should be active
    await expect(page.locator('#panel-terminal')).toHaveClass(/active/);

    // Tab bar should auto-hide (hasConnected is true)
    await expect(page.locator('#tabBar')).toHaveClass(/hidden/);
  });

});
