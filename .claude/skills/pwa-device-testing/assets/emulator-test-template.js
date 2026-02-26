/**
 * tests/emulator/<name>.spec.js — Template
 *
 * Emulator test template for real Chrome on Android via CDP.
 * Screen recording is handled externally by run-emulator-tests.sh.
 * Use screenshot() at each decision point for the Playwright HTML report.
 *
 * Run all:  npm run test:emulator
 * Run one:  bash scripts/run-emulator-tests.sh <name>.spec.js
 */

const { test, expect, screenshot } = require('./fixtures');

test.describe('<Feature name> (Android emulator)', () => {

  test('basic page load and render', async ({ emulatorPage: page }, testInfo) => {
    // emulatorPage fixture has already:
    //   1. Connected to Chrome via worker-scoped CDP
    //   2. Opened a new tab
    //   3. Navigated to BASE_URL, cleared localStorage, reloaded
    //
    // The page is ready with clean state.
    await page.waitForSelector('.xterm-screen', { timeout: 30_000 });
    await screenshot(page, testInfo, '01-initial-state');

    // --- Your assertions here ---

    await screenshot(page, testInfo, '02-after-action');
  });

  test('interaction requiring real Chrome', async ({ emulatorPage: page }, testInfo) => {
    await page.waitForSelector('.xterm-screen', { timeout: 30_000 });

    // Switch panels, fill forms, etc.
    // Use semantic selectors — elements may not have IDs:
    //   GOOD: page.locator('#connectForm button[type="submit"]')
    //   BAD:  page.locator('#connectBtn')
    await page.locator('[data-panel="connect"]').click();
    await screenshot(page, testInfo, '03-connect-panel');

    // --- Your assertions here ---

    await screenshot(page, testInfo, '04-result');
  });

  // For tests that need pre-created state (vault, profiles, etc.),
  // inject it via page.evaluate on the already-loaded page.
  // Do NOT navigate again — the fixture already loaded the page.
  test('test requiring existing vault', async ({ emulatorPage: page }, testInfo) => {
    await page.waitForSelector('.xterm-screen', { timeout: 30_000 });

    // Create vault in-page (same pattern as headless tests)
    await page.evaluate(async () => {
      const { createVault } = await import('./modules/vault.js');
      await createVault('test-password', false);
    });

    // --- Now vault exists, test vault-dependent features ---

    await screenshot(page, testInfo, '05-with-vault');
  });
});
