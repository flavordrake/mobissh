/**
 * tests/settings.spec.js
 *
 * Settings panel — test gate for Phase 6 module extraction (#110).
 * Tests WS URL persistence, ws:// rejection, danger zone toggles,
 * and clear data functionality.
 */

const { test, expect } = require('./fixtures.js');

test.describe('Settings panel (#110 Phase 6)', () => {

  test('saving a wss:// URL persists to localStorage', async ({ page }) => {
    await page.addInitScript(() => { localStorage.clear(); });
    await page.goto('./');
    await page.waitForSelector('.xterm-screen', { timeout: 8000 });

    await page.locator('[data-panel="settings"]').click();
    await page.locator('#wsUrl').fill('wss://custom.example.com/ws');
    await page.locator('#saveSettingsBtn').click();
    await page.waitForTimeout(300);

    const saved = await page.evaluate(() => localStorage.getItem('wsUrl'));
    expect(saved).toBe('wss://custom.example.com/ws');
  });

  test('ws:// URL is rejected when danger zone toggle is off', async ({ page }) => {
    await page.addInitScript(() => { localStorage.clear(); });
    await page.goto('./');
    await page.waitForSelector('.xterm-screen', { timeout: 8000 });

    await page.locator('[data-panel="settings"]').click();
    await page.locator('#wsUrl').fill('ws://insecure.example.com/ws');
    await page.locator('#saveSettingsBtn').click();
    await page.waitForTimeout(300);

    const saved = await page.evaluate(() => localStorage.getItem('wsUrl'));
    expect(saved).toBeNull();

    const toastText = await page.locator('#toast').textContent();
    expect(toastText).toContain('ws://');
  });

  test('ws:// URL is accepted when danger zone toggle is on', async ({ page }) => {
    await page.addInitScript(() => { localStorage.clear(); });
    await page.goto('./');
    await page.waitForSelector('.xterm-screen', { timeout: 8000 });

    await page.locator('[data-panel="settings"]').click();

    // The checkbox is visually hidden by custom toggle CSS; set via evaluate
    await page.evaluate(() => {
      const el = document.getElementById('dangerAllowWs');
      el.checked = true;
      el.dispatchEvent(new Event('change'));
    });
    await page.waitForTimeout(100);

    await page.locator('#wsUrl').fill('ws://allowed.example.com/ws');
    await page.locator('#saveSettingsBtn').click();
    await page.waitForTimeout(300);

    const saved = await page.evaluate(() => localStorage.getItem('wsUrl'));
    expect(saved).toBe('ws://allowed.example.com/ws');
  });

  test('danger zone toggle persists to localStorage', async ({ page }) => {
    await page.addInitScript(() => { localStorage.clear(); });
    await page.goto('./');
    await page.waitForSelector('.xterm-screen', { timeout: 8000 });

    await page.locator('[data-panel="settings"]').click();

    // Should start unchecked
    const before = await page.evaluate(() => document.getElementById('dangerAllowWs').checked);
    expect(before).toBe(false);

    // Check via evaluate (hidden by custom toggle CSS)
    await page.evaluate(() => {
      const el = document.getElementById('dangerAllowWs');
      el.checked = true;
      el.dispatchEvent(new Event('change'));
    });
    await page.waitForTimeout(100);

    const stored = await page.evaluate(() => localStorage.getItem('dangerAllowWs'));
    expect(stored).toBe('true');
  });

  test('clear data resets localStorage and profile list', async ({ page }) => {
    await page.addInitScript(() => { localStorage.clear(); });
    await page.goto('./');
    await page.waitForSelector('.xterm-screen', { timeout: 8000 });

    // Seed a profile after page load so xterm-screen is visible
    await page.evaluate(() => {
      localStorage.setItem('sshProfiles', JSON.stringify([
        { name: 'test', host: 'h', port: 22, username: 'u' },
      ]));
    });

    page.on('dialog', dialog => dialog.accept());

    await page.locator('[data-panel="settings"]').click();
    // resetAppBtn clears all data, caches, and reloads; wait for navigation
    const [navigation] = await Promise.all([
      page.waitForNavigation({ timeout: 8000 }),
      page.evaluate(() => document.getElementById('resetAppBtn').click()),
    ]);

    const profiles = await page.evaluate(() => localStorage.getItem('sshProfiles'));
    expect(profiles).toBeNull();
  });

  test('font size slider updates localStorage', async ({ page }) => {
    await page.addInitScript(() => { localStorage.clear(); });
    await page.goto('./');
    await page.waitForSelector('.xterm-screen', { timeout: 8000 });

    await page.locator('[data-panel="settings"]').click();
    await page.locator('#fontSize').fill('18');
    await page.locator('#fontSize').dispatchEvent('input');
    await page.waitForTimeout(200);

    const saved = await page.evaluate(() => localStorage.getItem('fontSize'));
    expect(saved).toBe('18');
  });

});
