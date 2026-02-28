/**
 * tests/browserstack-smoke.spec.js
 *
 * Phase 1 smoke test for BrowserStack real-device runs.
 * Verifies the PWA shell loads correctly on real Android/iOS hardware.
 *
 * What this test does NOT do:
 *   - No SSH connections
 *   - No credential vault / PasswordCredential tests
 *   - No WebAuthn flows
 *
 * Run via: npm run test:browserstack
 * Devices are declared in browserstack.yml (Samsung S23, Pixel 6, iPhone 15).
 */

const { test, expect } = require('./fixtures.js');

test('smoke: page loads, title is MobiSSH, connect form and tab bar render', async ({ page }) => {
  await page.goto('./');

  // Wait for xterm.js to initialise — real devices can be slower than emulators
  await page.waitForSelector('.xterm-screen', { timeout: 30_000 });

  // 1. Page title
  await expect(page).toHaveTitle(/MobiSSH/);

  // 2. Tab bar renders with all four tabs
  const tabBar = page.locator('#tabBar');
  await expect(tabBar).toBeVisible();
  await expect(page.locator('[data-panel="terminal"]')).toBeVisible();
  await expect(page.locator('[data-panel="connect"]')).toBeVisible();
  await expect(page.locator('[data-panel="keys"]')).toBeVisible();
  await expect(page.locator('[data-panel="settings"]')).toBeVisible();

  // 3. Connect form is visible after clicking the Connect tab
  await page.locator('[data-panel="connect"]').click();
  const connectPanel = page.locator('#panel-connect');
  await expect(connectPanel).toHaveClass(/active/);
  await expect(page.locator('#host')).toBeVisible();
  await expect(page.locator('#port')).toBeVisible();
  await expect(page.locator('#remote_a')).toBeVisible();

  // 4. Screenshot (saved by BrowserStack Automate and available in the dashboard)
  await page.screenshot({ path: 'test-results/screenshots/browserstack-smoke.png' });
});
