/**
 * tests/terminal.spec.js
 *
 * Terminal init, font size, theme, and resize tests (#110 Phase 10).
 */

const { test, expect } = require('./fixtures.js');

test.describe('Terminal (#110 Phase 10)', () => {
  test('xterm.js terminal is created and visible on load', async ({ page }) => {
    await page.addInitScript(() => { localStorage.clear(); });
    await page.goto('./');
    await page.waitForSelector('.xterm-screen', { timeout: 8000 });
    await expect(page.locator('.xterm-screen')).toBeVisible();
  });

  test('saved font size is applied on load', async ({ page }) => {
    await page.addInitScript(() => {
      localStorage.clear();
      localStorage.setItem('fontSize', '20');
    });
    await page.goto('./');
    await page.waitForSelector('.xterm-screen', { timeout: 8000 });

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
    await page.waitForSelector('.xterm-screen', { timeout: 8000 });

    // Settings selector should reflect saved theme
    const sel = page.locator('#termThemeSelect');
    await expect(sel).toHaveValue('solarizedDark');
  });

  test('font size change syncs slider, label, and menu label', async ({ page, mockSshServer }) => {
    await page.addInitScript(() => { localStorage.clear(); });
    await page.goto('./');
    await page.waitForSelector('.xterm-screen', { timeout: 8000 });

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
    await page.addInitScript(() => {
      window.__mockWsSpy = [];
      const OrigWS = window.WebSocket;
      window.WebSocket = class extends OrigWS {
        send(data) { window.__mockWsSpy.push(data); super.send(data); }
      };
    });
    await page.addInitScript(() => { localStorage.clear(); });
    await page.goto('./');
    await page.waitForSelector('.xterm-screen', { timeout: 8000 });

    // Pre-create a test vault so saveProfile() doesn't show the setup modal
    await page.evaluate(async () => {
      const { createVault } = await import('./modules/vault.js');
      await createVault('test', false);
    });

    await page.evaluate((port) => {
      localStorage.setItem('wsUrl', `ws://localhost:${port}`);
    }, mockSshServer.port);

    await page.locator('[data-panel="connect"]').click();
    await page.locator('#host').fill('mock-host');
    await page.locator('#remote_a').fill('testuser');
    await page.locator('#remote_c').fill('testpass');
    await page.locator('#connectForm button[type="submit"]').click();

    await page.waitForFunction(() => {
      return (window.__mockWsSpy || []).some((s) => {
        try { return JSON.parse(s).type === 'resize'; } catch (_) { return false; }
      });
    }, null, { timeout: 10_000 });

    await page.waitForSelector('#panel-terminal.active', { timeout: 5000 });

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
