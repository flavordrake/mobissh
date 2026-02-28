/**
 * tests/routing.spec.js
 *
 * Hash routing tests (#137). Verifies URL hash sync with panel switching,
 * browser back/forward, page refresh persistence, and cold-start priority.
 */

const { test, expect } = require('./fixtures.js');
const { setupConnected } = require('./fixtures.js');

test.describe('Hash routing (#137)', () => {

  test('tab click updates location.hash', async ({ page }) => {
    await page.goto('./');
    await page.waitForSelector('#tabBar', { state: 'attached' });

    await page.locator('[data-panel="connect"]').click();
    expect(await page.evaluate(() => location.hash)).toBe('#connect');

    await page.locator('[data-panel="settings"]').click();
    expect(await page.evaluate(() => location.hash)).toBe('#settings');

    await page.locator('[data-panel="keys"]').click();
    expect(await page.evaluate(() => location.hash)).toBe('#keys');

    await page.locator('[data-panel="terminal"]').click();
    expect(await page.evaluate(() => location.hash)).toBe('#terminal');
  });

  test('page load with #settings hash shows settings panel', async ({ page }) => {
    await page.goto('./#settings');
    await page.waitForSelector('#tabBar', { state: 'attached' });
    await expect(page.locator('#panel-settings')).toHaveClass(/active/);
  });

  test('page load with #keys hash shows keys panel', async ({ page }) => {
    await page.goto('./#keys');
    await page.waitForSelector('#tabBar', { state: 'attached' });
    await expect(page.locator('#panel-keys')).toHaveClass(/active/);
  });

  test('page refresh preserves current panel', async ({ page }) => {
    await page.goto('./');
    await page.waitForSelector('#tabBar', { state: 'attached' });
    await page.locator('[data-panel="settings"]').click();
    expect(await page.evaluate(() => location.hash)).toBe('#settings');

    await page.reload();
    await page.waitForSelector('#tabBar', { state: 'attached' });
    await expect(page.locator('#panel-settings')).toHaveClass(/active/);
  });

  test('browser back navigates to previous panel', async ({ page }) => {
    await page.goto('./');
    await page.waitForSelector('#tabBar', { state: 'attached' });

    await page.locator('[data-panel="connect"]').click();
    await page.locator('[data-panel="settings"]').click();

    await page.goBack();
    await expect(page.locator('#panel-connect')).toHaveClass(/active/);
  });

  test('browser forward navigates to next panel', async ({ page }) => {
    await page.goto('./');
    await page.waitForSelector('#tabBar', { state: 'attached' });

    await page.locator('[data-panel="connect"]').click();
    await page.locator('[data-panel="settings"]').click();

    await page.goBack();
    await expect(page.locator('#panel-connect')).toHaveClass(/active/);

    await page.goForward();
    await expect(page.locator('#panel-settings')).toHaveClass(/active/);
  });

  test('invalid hash falls back to terminal', async ({ page }) => {
    await page.goto('./#nonsense');
    await page.waitForSelector('#tabBar', { state: 'attached' });
    await expect(page.locator('#panel-terminal')).toHaveClass(/active/);
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

  test('cold start with profiles but #settings hash respects hash', async ({ page }) => {
    await page.addInitScript(() => {
      localStorage.setItem('sshProfiles', JSON.stringify([
        { name: 'test', host: 'x', port: 22, username: 'u', authType: 'password', vaultId: 'v' }
      ]));
    });
    await page.goto('./#settings');
    await page.waitForSelector('#tabBar', { state: 'attached' });
    await expect(page.locator('#panel-settings')).toHaveClass(/active/);
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
