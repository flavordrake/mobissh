/**
 * tests/vault.spec.js
 *
 * Credential vault (#14) — master-password + DEK/KEK architecture.
 * Tests encrypt/decrypt lifecycle, vault setup modal, unlock flow,
 * and the "never store plaintext" security invariant.
 */

const { test, expect, setupConnected, ensureTestVault } = require('./fixtures.js');

// After setupConnected the tab bar is auto-hidden (#36). Show it before switching tabs.
async function showTabBar(page) {
  await page.locator('#tabBarToggleBtn').click();
  await page.waitForSelector('#tabBar:not(.hidden)', { timeout: 2000 });
}

test.describe('Credential vault (#14)', () => {

  test('saving a profile stores encrypted credentials in sshVault (not plaintext)', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Save a new profile via the connect form
    await showTabBar(page);
    await page.locator('[data-panel="connect"]').click();
    await page.locator('#host').fill('vault-test-host');
    await page.locator('#port').fill('22');
    await page.locator('#username').fill('vaultuser');
    await page.locator('#password').fill('supersecretpassword');
    await page.locator('#connectForm button[type="submit"]').click();

    // Wait for profile to be saved
    await page.waitForTimeout(500);

    // Check localStorage: sshProfiles should NOT contain the password in plaintext
    const profiles = await page.evaluate(() => JSON.parse(localStorage.getItem('sshProfiles') || '[]'));
    const profile = profiles.find(p => p.host === 'vault-test-host');
    expect(profile).toBeTruthy();
    expect(profile.password).toBeUndefined();
    expect(profile.privateKey).toBeUndefined();
    expect(profile.passphrase).toBeUndefined();

    // The vault should have an encrypted entry
    const vault = await page.evaluate(() => JSON.parse(localStorage.getItem('sshVault') || '{}'));
    expect(Object.keys(vault).length).toBeGreaterThan(0);

    // The vault entry should have iv and ct (encrypted), not plaintext
    const vaultEntry = Object.values(vault)[0];
    expect(vaultEntry.iv).toBeTruthy();
    expect(vaultEntry.ct).toBeTruthy();
    // The ciphertext should NOT contain our plaintext password
    expect(vaultEntry.ct).not.toContain('supersecretpassword');
  });

  test('profile hasVaultCreds flag is set when credentials are vaulted', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    await showTabBar(page);
    await page.locator('[data-panel="connect"]').click();
    await page.locator('#host').fill('flag-test-host');
    await page.locator('#port').fill('22');
    await page.locator('#username').fill('flaguser');
    await page.locator('#password').fill('mypassword');
    await page.locator('#connectForm button[type="submit"]').click();
    await page.waitForTimeout(500);

    const profiles = await page.evaluate(() => JSON.parse(localStorage.getItem('sshProfiles') || '[]'));
    const profile = profiles.find(p => p.host === 'flag-test-host');
    expect(profile).toBeTruthy();
    expect(profile.hasVaultCreds).toBe(true);
    expect(profile.vaultId).toBeTruthy();
  });

  test('vault encrypt-decrypt roundtrip preserves credential data', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Save a profile with credentials
    await showTabBar(page);
    await page.locator('[data-panel="connect"]').click();
    await page.locator('#host').fill('roundtrip-host');
    await page.locator('#port').fill('22');
    await page.locator('#username').fill('rounduser');
    await page.locator('#password').fill('roundtrip-secret');
    await page.locator('#connectForm button[type="submit"]').click();
    await page.waitForTimeout(500);

    // Now click that profile to load it back into the form
    await showTabBar(page);
    await page.locator('[data-panel="connect"]').click();
    const profileItem = page.locator('.profile-item', { hasText: 'rounduser@roundtrip-host' });
    await profileItem.waitFor({ state: 'visible', timeout: 3000 });
    await profileItem.click();
    await page.waitForTimeout(500);

    // The password field should be populated with the decrypted value
    const password = await page.locator('#password').inputValue();
    expect(password).toBe('roundtrip-secret');
  });

  test('deleting a profile removes its vault entry', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Save a profile
    await showTabBar(page);
    await page.locator('[data-panel="connect"]').click();
    await page.locator('#host').fill('delete-test-host');
    await page.locator('#port').fill('22');
    await page.locator('#username').fill('deleteuser');
    await page.locator('#password').fill('deleteme');
    await page.locator('#connectForm button[type="submit"]').click();
    await page.waitForTimeout(500);

    // Get vault entry count before delete
    const vaultBefore = await page.evaluate(() => Object.keys(JSON.parse(localStorage.getItem('sshVault') || '{}')).length);
    expect(vaultBefore).toBeGreaterThan(0);

    // Delete the profile — navigate to Connect panel where profile list is visible
    await showTabBar(page);
    await page.locator('[data-panel="connect"]').click();
    const deleteBtn = page.locator('[data-action="delete"]').first();
    await deleteBtn.waitFor({ state: 'visible', timeout: 3000 });
    await deleteBtn.click();
    await page.waitForTimeout(300);

    // Vault entry should be removed
    const vaultAfter = await page.evaluate(() => Object.keys(JSON.parse(localStorage.getItem('sshVault') || '{}')).length);
    expect(vaultAfter).toBe(vaultBefore - 1);
  });

  test('without vault setup, credentials are not stored and modal appears', async ({ page, mockSshServer }) => {
    // Use setupConnected but DON'T pre-create vault — we need a special flow
    // Navigate manually without setupConnected to avoid the auto-vault
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

    await page.locator('[data-panel="connect"]').click();
    await page.locator('#host').fill('no-vault-host');
    await page.locator('#port').fill('22');
    await page.locator('#username').fill('novaultuser');
    await page.locator('#password').fill('should-not-persist');

    // Submit — vault setup modal should appear since no vault exists
    await page.locator('#connectForm button[type="submit"]').click();
    await page.waitForSelector('#vaultSetupOverlay:not(.hidden)', { timeout: 5000 });

    // Cancel the vault setup
    await page.locator('#vaultSetupCancel').click();
    await expect(page.locator('#vaultSetupOverlay')).toHaveClass(/hidden/, { timeout: 2000 });

    // Profile metadata should still be saved (just without vault creds)
    await page.waitForTimeout(500);
    const profiles = await page.evaluate(() => JSON.parse(localStorage.getItem('sshProfiles') || '[]'));
    const profile = profiles.find(p => p.host === 'no-vault-host');
    expect(profile).toBeTruthy();
    expect(profile.password).toBeUndefined();
    expect(profile.hasVaultCreds).toBeFalsy();
  });

  test('vault setup modal creates vault and encrypts credentials', async ({ page }) => {
    await page.addInitScript(() => { localStorage.clear(); });
    await page.goto('./');
    await page.waitForSelector('.xterm-screen', { timeout: 8000 });

    await page.locator('[data-panel="connect"]').click();
    await page.locator('#host').fill('setup-test-host');
    await page.locator('#port').fill('22');
    await page.locator('#username').fill('setupuser');
    await page.locator('#password').fill('setupsecret');

    // Submit — triggers vault setup modal
    await page.locator('#connectForm button[type="submit"]').click();
    await page.waitForSelector('#vaultSetupOverlay:not(.hidden)', { timeout: 5000 });

    // Fill in master password and create vault (uncheck biometric — no authenticator in headless)
    await page.locator('#vaultNewPw').fill('masterpass');
    await page.locator('#vaultConfirmPw').fill('masterpass');
    await page.evaluate(() => {
      const cb = document.getElementById('vaultEnableBio');
      if (cb) cb.checked = false;
    });
    await page.locator('#vaultSetupCreate').click();

    // Modal should close (PBKDF2 600k iterations takes ~300-500ms in browser)
    await expect(page.locator('#vaultSetupOverlay')).toHaveClass(/hidden/, { timeout: 10000 });
    await page.waitForTimeout(500);

    // vaultMeta should exist in localStorage
    const meta = await page.evaluate(() => JSON.parse(localStorage.getItem('vaultMeta') || 'null'));
    expect(meta).toBeTruthy();
    expect(meta.salt).toBeTruthy();
    expect(meta.dekPw).toBeTruthy();
    expect(meta.dekPw.iv).toBeTruthy();
    expect(meta.dekPw.ct).toBeTruthy();

    // Profile should have vault creds
    const profiles = await page.evaluate(() => JSON.parse(localStorage.getItem('sshProfiles') || '[]'));
    const profile = profiles.find(p => p.host === 'setup-test-host');
    expect(profile).toBeTruthy();
    expect(profile.hasVaultCreds).toBe(true);
  });

  test('vault settings section shows correct status', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Vault was created by setupConnected (via ensureTestVault) — refresh settings UI
    await page.evaluate(async () => {
      const { updateVaultSettingsUI } = await import('./modules/vault-ui.js');
      updateVaultSettingsUI();
    });

    await showTabBar(page);
    await page.locator('[data-panel="settings"]').click();

    // Status should show unlocked
    const status = await page.locator('#vaultStatus').textContent();
    expect(status).toContain('Unlocked');

    // Lock, Change Password, and Reset buttons should be visible
    await expect(page.locator('#vaultLockBtn')).toBeVisible();
    await expect(page.locator('#vaultChangePwBtn')).toBeVisible();
    await expect(page.locator('#vaultResetBtn')).toBeVisible();
  });

  test('lock button locks vault and updates status', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Refresh settings UI after test vault creation
    await page.evaluate(async () => {
      const { updateVaultSettingsUI } = await import('./modules/vault-ui.js');
      updateVaultSettingsUI();
    });

    await showTabBar(page);
    await page.locator('[data-panel="settings"]').click();

    // Click lock
    await page.locator('#vaultLockBtn').click();
    await page.waitForTimeout(200);

    const status = await page.locator('#vaultStatus').textContent();
    expect(status).toBe('Locked');

    // Lock button should be hidden when locked
    await expect(page.locator('#vaultLockBtn')).not.toBeVisible();
  });

});
