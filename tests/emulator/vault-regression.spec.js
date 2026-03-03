/**
 * tests/emulator/vault-regression.spec.js
 *
 * Regression tests for vault overhaul (#14, #98).
 * These tests exist to prove, with screenshot evidence, that the master
 * password vault works correctly on real Chrome and that the old
 * PasswordCredential autofill interference (#98) is gone.
 *
 * Each test captures before/during/after screenshots at decision points.
 * The HTML report (playwright-report-emulator/) is the proof artifact.
 *
 * Run: npx playwright test --config=playwright.emulator.config.js tests/emulator/vault-regression.spec.js
 */

const { test, expect, screenshot, BASE_URL } = require('./fixtures');

test.describe('Vault regression — #98 autofill interference fix', () => {

  test('no Chrome "Save password?" prompt during credential save flow', async ({ cleanPage: page }, testInfo) => {
    // Core #98 regression test. cleanPage gives us empty localStorage, no vault.
    // Vault setup modal appears on startup — create vault first, then test
    // that submitting the connect form doesn't trigger Chrome autofill.

    // Create vault from the startup modal
    await page.waitForSelector('#vaultSetupOverlay:not(.hidden)', { timeout: 10_000 });
    await page.locator('#vaultNewPw').fill('master-pw-test');
    await page.locator('#vaultConfirmPw').fill('master-pw-test');
    await page.evaluate(() => {
      const cb = document.getElementById('vaultEnableBio');
      if (cb) cb.checked = false;
    });
    await page.evaluate(() => document.getElementById('vaultSetupCreate')?.click());
    await page.locator('#vaultSetupOverlay').waitFor({ state: 'hidden', timeout: 5000 });
    await screenshot(page, testInfo, 'regression-01-vault-created');

    // Now fill and submit the connect form — this is where #98 triggered
    await page.locator('[data-panel="connect"]').click();
    await page.waitForSelector('#panel-connect.active', { timeout: 5000 });
    await page.locator('#host').fill('regression-test-host');
    await page.locator('#port').fill('22');
    await page.locator('#remote_a').fill('testuser');
    await page.locator('#remote_c').fill('secretpassword123');
    await screenshot(page, testInfo, 'regression-02-form-filled');

    await page.locator('#connectForm button[type="submit"]').click();
    await page.waitForTimeout(2000);
    await screenshot(page, testInfo, 'regression-03-after-submit-no-autofill');

    // CRITICAL: verify password field has suppression attributes
    const pwAttrs = await page.locator('#remote_c').evaluate(el => ({
      type: el.type,
      autocomplete: el.getAttribute('autocomplete'),
      lpIgnore: el.getAttribute('data-lpignore'),
      onePIgnore: el.getAttribute('data-1p-ignore'),
      formType: el.getAttribute('data-form-type'),
    }));
    expect(pwAttrs.type).toBe('text');
    expect(pwAttrs.autocomplete).toBe('off');
    expect(pwAttrs.lpIgnore).toBe('true');
    expect(pwAttrs.onePIgnore).toBe('true');
    expect(pwAttrs.formType).toBe('other');

    // Same check for the passphrase field
    const ppAttrs = await page.locator('#remote_pp').evaluate(el => ({
      type: el.type,
      autocomplete: el.getAttribute('autocomplete'),
    }));
    expect(ppAttrs.type).toBe('text');
    expect(ppAttrs.autocomplete).toBe('off');
    await screenshot(page, testInfo, 'regression-04-final-state-no-autofill');
  });

  test('PasswordCredential API is not called anywhere in the app', async ({ cleanPage: page }, testInfo) => {
    // Instrument the page to detect any PasswordCredential usage.
    // Must be added via addInitScript BEFORE navigation, so we re-navigate.
    await page.addInitScript(() => {
      window.__passwordCredentialCalled = false;
      window.__credentialsStoreCalled = false;

      if (typeof window.PasswordCredential !== 'undefined') {
        const OrigPC = window.PasswordCredential;
        window.PasswordCredential = function (...args) {
          window.__passwordCredentialCalled = true;
          return new OrigPC(...args);
        };
        window.PasswordCredential.prototype = OrigPC.prototype;
      }

      if (navigator.credentials && navigator.credentials.store) {
        const origStore = navigator.credentials.store.bind(navigator.credentials);
        navigator.credentials.store = function (...args) {
          window.__credentialsStoreCalled = true;
          return origStore(...args);
        };
      }
    });

    // Re-navigate so initScript takes effect
    await page.evaluate(() => localStorage.clear());
    await page.reload({ waitUntil: 'domcontentloaded' });

    // Vault setup modal appears on startup (no vault)
    await page.waitForSelector('#vaultSetupOverlay:not(.hidden)', { timeout: 10_000 });
    await page.locator('#vaultNewPw').fill('vault-pw');
    await page.locator('#vaultConfirmPw').fill('vault-pw');
    await page.evaluate(() => {
      const cb = document.getElementById('vaultEnableBio');
      if (cb) cb.checked = false;
    });
    await page.evaluate(() => document.getElementById('vaultSetupCreate')?.click());
    await page.locator('#vaultSetupOverlay').waitFor({ state: 'hidden', timeout: 5000 });
    await screenshot(page, testInfo, 'api-check-01-vault-created');

    // Go through the credential save flow
    await page.locator('[data-panel="connect"]').click();
    await page.waitForSelector('#panel-connect.active', { timeout: 5000 });
    await page.locator('#host').fill('api-check-host');
    await page.locator('#remote_a').fill('user');
    await page.locator('#remote_c').fill('pass');
    await page.locator('#connectForm button[type="submit"]').click();
    await page.waitForTimeout(2000);
    await screenshot(page, testInfo, 'api-check-02-flow-complete');

    // Verify: PasswordCredential was never constructed, credentials.store never called
    const apiUsage = await page.evaluate(() => ({
      passwordCredentialCalled: window.__passwordCredentialCalled,
      credentialsStoreCalled: window.__credentialsStoreCalled,
    }));

    expect(apiUsage.passwordCredentialCalled).toBe(false);
    expect(apiUsage.credentialsStoreCalled).toBe(false);
    await screenshot(page, testInfo, 'api-check-03-no-credential-api-used');
  });

  test('vault encrypts credentials — no plaintext in localStorage', async ({ cleanPage: page }, testInfo) => {
    // cleanPage: no vault. Create vault via startup modal, then save a profile,
    // then prove the password is not stored in plaintext.

    // Create vault from startup modal
    await page.waitForSelector('#vaultSetupOverlay:not(.hidden)', { timeout: 10_000 });
    await page.locator('#vaultNewPw').fill('test-master');
    await page.locator('#vaultConfirmPw').fill('test-master');
    await page.evaluate(() => {
      const cb = document.getElementById('vaultEnableBio');
      if (cb) cb.checked = false;
    });
    await page.evaluate(() => document.getElementById('vaultSetupCreate')?.click());
    await page.locator('#vaultSetupOverlay').waitFor({ state: 'hidden', timeout: 5000 });

    // Save a profile with credentials
    await page.locator('[data-panel="connect"]').click();
    await page.locator('#host').fill('plaintext-check-host');
    await page.locator('#remote_a').fill('secretuser');
    await page.locator('#remote_c').fill('hunter2-should-not-appear');
    await page.locator('#connectForm button[type="submit"]').click();
    await page.waitForTimeout(2000);
    await screenshot(page, testInfo, 'plaintext-01-profile-saved');

    // Dump all of localStorage and search for the plaintext password
    const storageCheck = await page.evaluate(() => {
      const password = 'hunter2-should-not-appear';
      const dump = {};
      for (let i = 0; i < localStorage.length; i++) {
        const key = localStorage.key(i);
        dump[key] = localStorage.getItem(key);
      }
      const fullDump = JSON.stringify(dump);
      return {
        containsPlaintextPassword: fullDump.includes(password),
        hasVaultMeta: !!dump.vaultMeta,
        hasSshVault: !!dump.sshVault,
        profileKeys: dump.sshProfiles
          ? JSON.parse(dump.sshProfiles).map(p => Object.keys(p))
          : [],
      };
    });

    await screenshot(page, testInfo, 'plaintext-02-storage-inspected');

    // The password must NOT appear in plaintext anywhere in localStorage
    expect(storageCheck.containsPlaintextPassword).toBe(false);
    // Vault metadata must exist (proof encryption path was used)
    expect(storageCheck.hasVaultMeta).toBe(true);
    // Encrypted vault data must exist
    expect(storageCheck.hasSshVault).toBe(true);
  });
});
