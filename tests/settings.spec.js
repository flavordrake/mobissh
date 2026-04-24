/**
 * tests/settings.spec.js
 *
 * Settings panel — test gate for Phase 6 module extraction (#110).
 * Tests WS URL persistence, ws:// rejection, danger zone toggles,
 * and clear data functionality.
 *
 * Settings UX (refactored in dbccc86) is now overview → detail:
 *   - `#panel-settings` shows a category list by default
 *   - Fields live inside `.settings-detail[data-section="..."]` sections
 *   - Click `.settings-category[data-section="server"]` to expose #wsUrl etc.
 *   - #fontSize, #termThemeSelect, #termFontSelect are in "terminal" section
 *   - #dangerAllowWs, #allowPrivateHosts, #resetAppBtn are in "advanced"
 */

const { test, expect } = require('./fixtures.js');

/** Open the Settings panel and drill into a category so its fields are reachable.
 *  Works even when a different detail section is currently active: calls
 *  showSettingsOverview() first via evaluate() to guarantee categories are visible. */
async function openSettingsSection(page, section) {
  await page.locator('#tabBar [data-panel="settings"]').click();
  // Ensure the overview is visible (a previous openSettingsSection call may have
  // left a detail-section active, which hides the category buttons).
  await page.evaluate(() => {
    document.getElementById('settingsOverview')?.classList.remove('hidden');
    document.querySelectorAll('.settings-detail').forEach((el) => el.classList.remove('active'));
  });
  await page.locator(`.settings-category[data-section="${section}"]`).click();
  // Wait for the detail section to become active
  await page.waitForSelector(`.settings-detail[data-section="${section}"].active`, { timeout: 2000 });
}

test.describe('Settings panel (#110 Phase 6)', { tag: '@headless-adequate' }, () => {

  test('saving a wss:// URL persists to localStorage', async ({ page }) => {
    await page.addInitScript(() => { localStorage.clear(); });
    await page.goto('./');
    await Promise.race([page.waitForSelector('#connectForm', { timeout: 8000 }), page.waitForSelector('.xterm-screen', { timeout: 8000 })]);

    await openSettingsSection(page, 'server');
    await page.locator('#wsUrl').fill('wss://custom.example.com/ws');
    await page.locator('#saveSettingsBtn').click();
    await page.waitForTimeout(300);

    const saved = await page.evaluate(() => localStorage.getItem('wsUrl'));
    expect(saved).toBe('wss://custom.example.com/ws');
  });

  test('ws:// URL is rejected when danger zone toggle is off', async ({ page }) => {
    await page.addInitScript(() => { localStorage.clear(); });
    await page.goto('./');
    await Promise.race([page.waitForSelector('#connectForm', { timeout: 8000 }), page.waitForSelector('.xterm-screen', { timeout: 8000 })]);

    await openSettingsSection(page, 'server');
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
    await Promise.race([page.waitForSelector('#connectForm', { timeout: 8000 }), page.waitForSelector('.xterm-screen', { timeout: 8000 })]);

    // Enable the danger-zone toggle (it lives in the "advanced" section)
    await openSettingsSection(page, 'advanced');
    await page.evaluate(() => {
      const el = document.getElementById('dangerAllowWs');
      el.checked = true;
      el.dispatchEvent(new Event('change'));
    });
    await page.waitForTimeout(100);

    // Now drill into the server section to save the ws:// URL
    await openSettingsSection(page, 'server');
    await page.locator('#wsUrl').fill('ws://allowed.example.com/ws');
    await page.locator('#saveSettingsBtn').click();
    await page.waitForTimeout(300);

    const saved = await page.evaluate(() => localStorage.getItem('wsUrl'));
    expect(saved).toBe('ws://allowed.example.com/ws');
  });

  test('danger zone toggle persists to localStorage', async ({ page }) => {
    await page.addInitScript(() => { localStorage.clear(); });
    await page.goto('./');
    await Promise.race([page.waitForSelector('#connectForm', { timeout: 8000 }), page.waitForSelector('.xterm-screen', { timeout: 8000 })]);

    await openSettingsSection(page, 'advanced');

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
    await Promise.race([page.waitForSelector('#connectForm', { timeout: 8000 }), page.waitForSelector('.xterm-screen', { timeout: 8000 })]);

    // Seed a profile after page load so xterm-screen is visible
    await page.evaluate(() => {
      localStorage.setItem('sshProfiles', JSON.stringify([
        { name: 'test', host: 'h', port: 22, username: 'u' },
      ]));
    });

    page.on('dialog', dialog => dialog.accept());

    // #resetAppBtn lives in the "advanced" section
    await openSettingsSection(page, 'advanced');
    // resetAppBtn clears all data, caches, and reloads; wait for navigation
    await Promise.all([
      page.waitForNavigation({ timeout: 8000 }),
      page.evaluate(() => document.getElementById('resetAppBtn').click()),
    ]);

    const profiles = await page.evaluate(() => localStorage.getItem('sshProfiles'));
    expect(profiles).toBeNull();
  });

  test('font size slider updates localStorage', async ({ page }) => {
    await page.addInitScript(() => { localStorage.clear(); });
    await page.goto('./');
    await Promise.race([page.waitForSelector('#connectForm', { timeout: 8000 }), page.waitForSelector('.xterm-screen', { timeout: 8000 })]);

    // #fontSize lives in the "terminal" section
    await openSettingsSection(page, 'terminal');
    await page.locator('#fontSize').fill('18');
    await page.locator('#fontSize').dispatchEvent('input');
    await page.waitForTimeout(200);

    const saved = await page.evaluate(() => localStorage.getItem('fontSize'));
    expect(saved).toBe('18');
  });

});

// Agent hooks (#55) tests removed — feature no longer exists in codebase.
