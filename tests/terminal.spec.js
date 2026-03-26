/**
 * tests/terminal.spec.js
 *
 * Terminal init, font size, theme, and resize tests (#110 Phase 10).
 */

const { test, expect, setupConnected } = require('./fixtures.js');

test.describe('Terminal (#110 Phase 10)', { tag: '@device-critical' }, () => {
  test('xterm.js terminal is created and visible on load', async ({ page }) => {
    await page.addInitScript(() => { localStorage.clear(); });
    await page.goto('./');
    await Promise.race([page.waitForSelector('#connectForm', { timeout: 8000 }), page.waitForSelector('.xterm-screen', { timeout: 8000 })]);
    await expect(page.locator('.xterm-screen')).toBeVisible();
  });

  test('saved font size is applied on load', async ({ page }) => {
    await page.addInitScript(() => {
      localStorage.clear();
      localStorage.setItem('fontSize', '20');
    });
    await page.goto('./');
    await Promise.race([page.waitForSelector('#connectForm', { timeout: 8000 }), page.waitForSelector('.xterm-screen', { timeout: 8000 })]);

    // Settings slider should reflect saved value
    const slider = page.locator('#fontSize');
    await expect(slider).toHaveValue('20');
    await expect(page.locator('#fontSizeValue')).toHaveText('20px');
  });

  test('saved theme is applied on load', async ({ page }) => {
    await page.addInitScript(() => {
      localStorage.clear();
      localStorage.setItem('termTheme', 'solarizedDark');
    });
    await page.goto('./');
    await Promise.race([page.waitForSelector('#connectForm', { timeout: 8000 }), page.waitForSelector('.xterm-screen', { timeout: 8000 })]);

    // Settings selector should reflect saved theme
    const sel = page.locator('#termThemeSelect');
    await expect(sel).toHaveValue('solarizedDark');
  });

  test('font size change syncs slider, label, and menu label', async ({ page, mockSshServer }) => {
    await page.addInitScript(() => { localStorage.clear(); });
    await page.goto('./');
    await Promise.race([page.waitForSelector('#connectForm', { timeout: 8000 }), page.waitForSelector('.xterm-screen', { timeout: 8000 })]);

    // Navigate to settings and change font size
    await page.locator('[data-panel="settings"]').click();
    const slider = page.locator('#fontSize');
    await slider.fill('18');
    await slider.dispatchEvent('input');

    // Verify all UI synced
    await expect(page.locator('#fontSizeValue')).toHaveText('18px');
    await expect(page.locator('#fontSizeLabel')).toHaveText('18px');
    const saved = await page.evaluate(() => localStorage.getItem('fontSize'));
    expect(saved).toBe('18');
  });

  test('theme cycle via session menu changes theme without persisting', async ({ page, mockSshServer }) => {
    // Connect so session menu works
    await setupConnected(page, mockSshServer);

    // Open session menu and click theme button
    await page.locator('#sessionMenuBtn').click();
    await page.waitForTimeout(100);
    const themeBtnBefore = await page.locator('#sessionThemeBtn').textContent();
    expect(themeBtnBefore).toContain('Dark');

    await page.locator('#sessionThemeBtn').click();
    await page.waitForTimeout(100);
    const themeBtnAfter = await page.locator('#sessionThemeBtn').textContent();
    // Should have cycled to the next theme (not Dark anymore)
    expect(themeBtnAfter).not.toContain('Dark');

    // Should NOT persist to localStorage (session-only)
    const stored = await page.evaluate(() => localStorage.getItem('termTheme'));
    expect(stored).toBeNull();
  });
});
