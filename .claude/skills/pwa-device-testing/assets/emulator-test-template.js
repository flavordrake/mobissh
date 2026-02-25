/**
 * tests/emulator/<name>.spec.js
 *
 * Emulator test template — runs on real Chrome via Android emulator CDP.
 * Copy this file, rename, and fill in tests.
 *
 * Run: npx playwright test --config=playwright.emulator.config.js
 * Run one: npx playwright test --config=playwright.emulator.config.js tests/emulator/<name>.spec.js
 */

const { test, expect, screenshot, BASE_URL } = require('./fixtures');

test.describe('<Feature name> (Android emulator)', () => {

  test('basic page load and render', async ({ emulatorPage: page }, testInfo) => {
    // Fixture has already:
    //   1. Connected to Chrome via worker-scoped CDP
    //   2. Opened a new tab
    //   3. Navigated to BASE_URL and cleared localStorage
    //
    // Navigate fresh for this test:
    await page.goto(BASE_URL);
    await page.waitForSelector('.xterm-screen', { timeout: 30_000 });
    await screenshot(page, testInfo, '01-initial-state');

    // --- Your assertions here ---

    await screenshot(page, testInfo, '02-after-action');
  });

  test('interaction that needs real Chrome', async ({ emulatorPage: page }, testInfo) => {
    await page.goto(BASE_URL);
    await page.waitForSelector('.xterm-screen', { timeout: 30_000 });

    // Switch panels, fill forms, etc.
    await page.locator('[data-panel="connect"]').click();
    await screenshot(page, testInfo, '03-connect-panel');

    // --- Your assertions here ---

    await screenshot(page, testInfo, '04-result');
  });

  // For tests that modify vault/localStorage state significantly,
  // the fixture auto-clears localStorage before each test.
  // If you need a vault pre-created, do it inline:
  test('test requiring existing vault', async ({ emulatorPage: page }, testInfo) => {
    await page.goto(BASE_URL);
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
