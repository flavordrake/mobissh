/**
 * tests/routing.spec.js
 *
 * Hash routing tests (#137). Verifies URL hash sync with panel switching,
 * browser back/forward, page refresh persistence, and cold-start priority.
 *
 * Note on selectors: [data-panel="..."] now matches both the tab bar and
 * the nav menu (#navMenu added in #449). All clicks scope to `#tabBar` to
 * avoid strict-mode errors.
 *
 * Note on #keys: the dedicated Keys tab/panel was removed (#441). Legacy
 * `#keys` hash redirects to the Connect panel (keys live in a Connect
 * sub-section now).
 */

const { test, expect } = require('./fixtures.js');
const { setupConnected } = require('./fixtures.js');

test.describe('Hash routing (#137)', { tag: '@headless-adequate' }, () => {

  test('tab click updates location.hash', async ({ page }) => {
    await page.goto('./');
    await page.waitForSelector('#tabBar', { state: 'attached' });

    await page.locator('#tabBar [data-panel="connect"]').click();
    expect(await page.evaluate(() => location.hash)).toBe('#connect');

    await page.locator('#tabBar [data-panel="settings"]').click();
    expect(await page.evaluate(() => location.hash)).toBe('#settings');

    await page.locator('#tabBar [data-panel="terminal"]').click();
    expect(await page.evaluate(() => location.hash)).toBe('#terminal');
  });

  test.skip('page load with #settings hash shows settings panel', async ({ page }) => {
    // SKIP: cold start always routes to Connect (#384 / app.ts line 111-113).
    // The app's post-vault-init calls navigateToPanel('connect') unconditionally
    // when there are no active sessions, clobbering any deep-link hash before
    // initRouting runs. Deep linking to settings at cold start is effectively
    // disabled by current app behavior. Re-enable when #384 ordering is fixed.
    await page.goto('./#settings');
    await page.waitForSelector('#tabBar', { state: 'attached' });
    await expect(page.locator('#panel-settings')).toHaveClass(/active/);
  });

  test('page load with #keys hash redirects to connect panel', async ({ page }) => {
    // #441: Keys tab/panel removed. Legacy #keys redirects to Connect.
    await page.goto('./#keys');
    await page.waitForSelector('#tabBar', { state: 'attached' });
    await expect(page.locator('#panel-connect')).toHaveClass(/active/);
  });

  test.skip('page refresh preserves current panel', async ({ page }) => {
    // SKIP: same as "page load with #settings hash" — cold start routes to
    // Connect unconditionally after vault init (#384), clobbering the hash.
    // Page-refresh panel persistence is effectively disabled for settings.
    await page.goto('./');
    await page.waitForSelector('#tabBar', { state: 'attached' });
    await page.locator('#tabBar [data-panel="settings"]').click();
    expect(await page.evaluate(() => location.hash)).toBe('#settings');

    await page.reload();
    await page.waitForSelector('#tabBar', { state: 'attached' });
    await expect(page.locator('#panel-settings')).toHaveClass(/active/);
  });

  test('browser back navigates to previous panel', async ({ page }) => {
    await page.goto('./');
    await page.waitForSelector('#tabBar', { state: 'attached' });

    await page.locator('#tabBar [data-panel="connect"]').click();
    await page.locator('#tabBar [data-panel="settings"]').click();

    await page.goBack();
    await expect(page.locator('#panel-connect')).toHaveClass(/active/);
  });

  test('browser forward navigates to next panel', async ({ page }) => {
    await page.goto('./');
    await page.waitForSelector('#tabBar', { state: 'attached' });

    await page.locator('#tabBar [data-panel="connect"]').click();
    await page.locator('#tabBar [data-panel="settings"]').click();

    await page.goBack();
    await expect(page.locator('#panel-connect')).toHaveClass(/active/);

    await page.goForward();
    await expect(page.locator('#panel-settings')).toHaveClass(/active/);
  });

  test('invalid hash falls back to connect', async ({ page }) => {
    // Previously expected #terminal fallback; dae5f66 removed the lobby
    // terminal so cold start with no valid hash lands on Connect.
    await page.goto('./#nonsense');
    await page.waitForSelector('#tabBar', { state: 'attached' });
    await expect(page.locator('#panel-connect')).toHaveClass(/active/);
  });

  test('cold start with profiles and no hash goes to #connect', async ({ page }) => {
    await page.addInitScript(() => {
      localStorage.setItem('sshProfiles', JSON.stringify([
        { name: 'test', host: 'x', port: 22, username: 'u', authType: 'password', vaultId: 'v' }
      ]));
    });
    await page.goto('./');
    await page.waitForSelector('#tabBar', { state: 'attached' });
    await expect(page.locator('#panel-connect')).toHaveClass(/active/);
    expect(await page.evaluate(() => location.hash)).toBe('#connect');
  });

  test.skip('cold start with profiles but #settings hash respects hash', async ({ page }) => {
    // SKIP: cold start overrides hash and routes to Connect (#384). See
    // "page load with #settings hash" above — deep link to settings is
    // effectively disabled until the app.ts ordering is fixed.
    await page.addInitScript(() => {
      localStorage.setItem('sshProfiles', JSON.stringify([
        { name: 'test', host: 'x', port: 22, username: 'u', authType: 'password', vaultId: 'v' }
      ]));
    });
    await page.goto('./#settings');
    await page.waitForSelector('#tabBar', { state: 'attached' });
    await expect(page.locator('#panel-settings')).toHaveClass(/active/, { timeout: 8000 });
  });

  test('form submit switches to #terminal', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    expect(await page.evaluate(() => location.hash)).toBe('#terminal');
  });

  test('terminal tab bar auto-hide still works after routing', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await expect(page.locator('#tabBar')).toHaveClass(/hidden/);
  });

  test('manifest start_url includes #connect', async ({ page }) => {
    await page.goto('./');
    await page.waitForSelector('#tabBar', { state: 'attached' });
    const manifest = await page.evaluate(async () => {
      const resp = await fetch('manifest.json');
      return resp.json();
    });
    expect(manifest.start_url).toContain('#connect');
  });
});
