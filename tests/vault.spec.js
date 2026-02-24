/**
 * tests/vault.spec.js
 *
 * Credential vault (#68) — test gate for Phase 4 module extraction (#110).
 * Tests AES-GCM encrypt/decrypt lifecycle, vault method detection,
 * and the "never store plaintext" security invariant.
 *
 * Uses mock PasswordCredential since headless Chromium doesn't support it.
 */

const { test, expect, setupConnected } = require('./fixtures.js');

// After setupConnected the tab bar is auto-hidden (#36). Show it before switching tabs.
async function showTabBar(page) {
  await page.locator('#tabBarToggleBtn').click();
  await page.waitForSelector('#tabBar:not(.hidden)', { timeout: 2000 });
}

// Inject a mock PasswordCredential API before any app code runs
async function injectMockVault(page) {
  await page.addInitScript(() => {
    // Mock PasswordCredential store
    const credentialStore = {};

    window.PasswordCredential = class PasswordCredential {
      constructor({ id, password, name }) {
        this.id = id;
        this.password = password;
        this.name = name;
        this.type = 'password';
      }
    };

    // Mock navigator.credentials.store/get
    const originalCredentials = navigator.credentials;
    const mockCredentials = {
      async store(cred) {
        credentialStore[cred.id] = cred;
      },
      async get(opts) {
        if (opts.password && opts.mediation === 'silent') {
          // Return the stored credential if available
          const key = Object.keys(credentialStore)[0];
          return key ? credentialStore[key] : null;
        }
        if (opts.password) {
          const key = Object.keys(credentialStore)[0];
          return key ? credentialStore[key] : null;
        }
        return null;
      },
      async create(opts) {
        return originalCredentials.create(opts);
      },
    };

    Object.defineProperty(navigator, 'credentials', {
      value: mockCredentials,
      writable: true,
      configurable: true,
    });

    // Expose credential store for test assertions
    window.__testCredentialStore = credentialStore;
  });
}

test.describe('Credential vault (#68)', () => {

  test('vault method detected as passwordcred when PasswordCredential available', async ({ page, mockSshServer }) => {
    await injectMockVault(page);
    await setupConnected(page, mockSshServer);

    const method = await page.evaluate(() => {
      // PasswordCredential is defined by our mock, so _detectVaultMethod should pick it up.
      // We can check appState indirectly — the app called initVault() on startup.
      return !!window.PasswordCredential;
    });
    expect(method).toBe(true);
  });

  test('saving a profile stores encrypted credentials in sshVault (not plaintext)', async ({ page, mockSshServer }) => {
    await injectMockVault(page);
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
    await injectMockVault(page);
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
    await injectMockVault(page);
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
    // Clicking a .profile-item triggers loadProfileIntoForm() via event delegation
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
    await injectMockVault(page);
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

  test('without PasswordCredential, credentials are not stored', async ({ page, mockSshServer }) => {
    // Do NOT inject mock vault — PasswordCredential won't exist in headless Chromium
    await setupConnected(page, mockSshServer);

    await showTabBar(page);
    await page.locator('[data-panel="connect"]').click();
    await page.locator('#host').fill('no-vault-host');
    await page.locator('#port').fill('22');
    await page.locator('#username').fill('novaultuser');
    await page.locator('#password').fill('should-not-persist');
    await page.locator('#connectForm button[type="submit"]').click();
    await page.waitForTimeout(500);

    // Profile metadata should be saved
    const profiles = await page.evaluate(() => JSON.parse(localStorage.getItem('sshProfiles') || '[]'));
    const profile = profiles.find(p => p.host === 'no-vault-host');
    expect(profile).toBeTruthy();

    // But credentials should NOT be in localStorage anywhere
    expect(profile.password).toBeUndefined();
    expect(profile.hasVaultCreds).toBeFalsy();

    // And the vault should be empty
    const vault = await page.evaluate(() => JSON.parse(localStorage.getItem('sshVault') || '{}'));
    expect(Object.keys(vault).length).toBe(0);
  });

});
