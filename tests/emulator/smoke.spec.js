/**
 * tests/emulator/smoke.spec.js
 *
 * PWA smoke test running on real Chrome via the Android emulator.
 * Screenshots are attached to the test report at each decision point.
 *
 * Run: npx playwright test --config=playwright.emulator.config.js
 */

const { test, expect, screenshot, BASE_URL } = require('./fixtures');

test.describe('PWA smoke (Android emulator)', () => {

  test('page loads and renders MobiSSH shell', async ({ emulatorPage: page }, testInfo) => {
    await page.goto(BASE_URL);
    await screenshot(page, testInfo, '01-initial-load');

    // Title
    await expect(page).toHaveTitle(/MobiSSH/);

    // xterm.js canvas initialises
    await page.waitForSelector('.xterm-screen', { timeout: 30_000 });
    await screenshot(page, testInfo, '02-terminal-rendered');

    // Tab bar visible with all four tabs
    await expect(page.locator('#tabBar')).toBeVisible();
    await expect(page.locator('[data-panel="terminal"]')).toBeVisible();
    await expect(page.locator('[data-panel="connect"]')).toBeVisible();
    await expect(page.locator('[data-panel="keys"]')).toBeVisible();
    await expect(page.locator('[data-panel="settings"]')).toBeVisible();
  });

  test('connect form renders and accepts input', async ({ emulatorPage: page }, testInfo) => {
    await page.goto(BASE_URL);
    await page.waitForSelector('.xterm-screen', { timeout: 30_000 });

    // Switch to Connect tab
    await page.locator('[data-panel="connect"]').click();
    await expect(page.locator('#panel-connect')).toHaveClass(/active/);
    await screenshot(page, testInfo, '03-connect-panel');

    // Fill the form
    await page.locator('#host').fill('emulator-test-host');
    await page.locator('#port').fill('22');
    await page.locator('#remote_a').fill('testuser');
    await page.locator('#remote_c').fill('testpass');
    await screenshot(page, testInfo, '04-form-filled');

    // Verify fields hold their values
    await expect(page.locator('#host')).toHaveValue('emulator-test-host');
    await expect(page.locator('#remote_a')).toHaveValue('testuser');
  });

  test('settings panel renders with vault section', async ({ emulatorPage: page }, testInfo) => {
    await page.goto(BASE_URL);
    await page.waitForSelector('.xterm-screen', { timeout: 30_000 });

    // Switch to Settings tab
    await page.locator('[data-panel="settings"]').click();
    await expect(page.locator('#panel-settings')).toHaveClass(/active/);
    await screenshot(page, testInfo, '05-settings-panel');

    // Font size slider exists
    await expect(page.locator('#fontSize')).toBeVisible();

    // Vault section exists
    await expect(page.locator('#vaultStatus')).toBeVisible();
    await screenshot(page, testInfo, '06-vault-settings');
  });

  test('vault setup modal appears on first credential save', async ({ emulatorPage: page }, testInfo) => {
    await page.goto(BASE_URL);
    await page.waitForSelector('.xterm-screen', { timeout: 30_000 });

    // Clear any existing vault/profiles
    await page.evaluate(() => localStorage.clear());
    await page.reload();
    await page.waitForSelector('.xterm-screen', { timeout: 30_000 });

    // Fill connect form and submit to trigger vault setup
    await page.locator('[data-panel="connect"]').click();
    await page.locator('#host').fill('vault-test-host');
    await page.locator('#port').fill('22');
    await page.locator('#remote_a').fill('vaultuser');
    await page.locator('#remote_c').fill('vaultpass');
    await screenshot(page, testInfo, '07-pre-vault-setup');

    await page.locator('#connectForm button[type="submit"]').click();

    // Vault setup modal should appear (no vault exists yet)
    await page.waitForSelector('#vaultSetupOverlay:not(.hidden)', { timeout: 10_000 });
    await screenshot(page, testInfo, '08-vault-setup-modal');

    // Verify the modal has the expected fields
    await expect(page.locator('#vaultNewPw')).toBeVisible();
    await expect(page.locator('#vaultConfirmPw')).toBeVisible();
    await expect(page.locator('#vaultSetupCreate')).toBeVisible();

    // Fill master password
    await page.locator('#vaultNewPw').fill('emulator-test-pw');
    await page.locator('#vaultConfirmPw').fill('emulator-test-pw');
    await screenshot(page, testInfo, '09-vault-password-filled');

    // Uncheck biometric if visible (emulator may not have enrolled fingerprint)
    await page.evaluate(() => {
      const cb = document.getElementById('vaultEnableBio');
      if (cb) cb.checked = false;
    });

    // Create vault
    await page.locator('#vaultSetupCreate').click();
    await expect(page.locator('#vaultSetupOverlay')).toHaveClass(/hidden/, { timeout: 15_000 });
    await screenshot(page, testInfo, '10-vault-created');

    // Vault meta should be in localStorage
    const hasMeta = await page.evaluate(() => !!localStorage.getItem('vaultMeta'));
    expect(hasMeta).toBe(true);
  });

  test('autofill suppression attributes present on sensitive fields', async ({ emulatorPage: page }, testInfo) => {
    await page.goto(BASE_URL);
    await page.waitForSelector('.xterm-screen', { timeout: 30_000 });
    await screenshot(page, testInfo, '11-before-autofill-check');

    // Check vault password fields (in DOM even when overlay is hidden)
    const vaultAttrs = await page.locator('#vaultNewPw').evaluate(el => ({
      lpIgnore: el.getAttribute('data-lpignore'),
      onePIgnore: el.getAttribute('data-1p-ignore'),
      formType: el.getAttribute('data-form-type'),
      autocomplete: el.getAttribute('autocomplete'),
    }));
    expect(vaultAttrs.lpIgnore).toBe('true');
    expect(vaultAttrs.onePIgnore).toBe('true');
    expect(vaultAttrs.formType).toBe('other');
    expect(vaultAttrs.autocomplete).toBe('new-password');

    // Check connect form password field — must be type="text" not "password" (#98)
    const connectAttrs = await page.locator('#remote_c').evaluate(el => ({
      type: el.type,
      lpIgnore: el.getAttribute('data-lpignore'),
      onePIgnore: el.getAttribute('data-1p-ignore'),
      formType: el.getAttribute('data-form-type'),
      autocomplete: el.getAttribute('autocomplete'),
    }));
    expect(connectAttrs.type).toBe('text');
    expect(connectAttrs.autocomplete).toBe('off');
    expect(connectAttrs.lpIgnore).toBe('true');
    expect(connectAttrs.onePIgnore).toBe('true');
    expect(connectAttrs.formType).toBe('other');
    await screenshot(page, testInfo, '12-autofill-attrs-verified');
  });
});
