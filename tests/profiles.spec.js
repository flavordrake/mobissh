/**
 * tests/profiles.spec.js
 *
 * Profile & key storage — test gate for Phase 5 module extraction (#110).
 * Tests profile upsert, XSS sanitisation, key import validation,
 * profile deletion, and form population on load.
 */

const { test, expect, setupConnected, openConnectAdvanced } = require('./fixtures.js');

// After setupConnected the tab bar is auto-hidden (#36). Show it so we can navigate.
async function showTabBar(page) {
  // Use evaluate because the hamburger button is only in the terminal panel,
  // and the test may not be on that panel when it needs tab bar access.
  await page.evaluate(() => {
    document.getElementById('tabBar')?.classList.remove('hidden');
    document.documentElement.style.setProperty('--tab-height', '56px');
  });
  await page.waitForSelector('#tabBar:not(.hidden)', { timeout: 2000 });
}

// Click the Connect tab. [data-panel="connect"] matches both the tab bar and
// the nav menu (#449) — scope to the tab bar to avoid strict-mode violations.
async function clickConnectTab(page) {
  await page.locator('#tabBar [data-panel="connect"]').click();
}

// Reveal the connect form. The form is inside <details id="connect-form-section">
// — open it directly. #newConnBtn was removed.
async function revealConnectForm(page) {
  await page.evaluate(() => {
    const d = document.getElementById('connect-form-section');
    if (d && 'open' in d) d.open = true;
  });
}

// Inject mock PasswordCredential so vault operations work in headless Chromium
async function injectMockVault(page) {
  await page.addInitScript(() => {
    const credentialStore = {};
    window.PasswordCredential = class PasswordCredential {
      constructor({ id, password, name }) {
        this.id = id;
        this.password = password;
        this.name = name;
        this.type = 'password';
      }
    };
    const mockCredentials = {
      async store(cred) { credentialStore[cred.id] = cred; },
      async get(opts) {
        if (opts.password) {
          const key = Object.keys(credentialStore)[0];
          return key ? credentialStore[key] : null;
        }
        return null;
      },
      async create(opts) { return navigator.credentials.create(opts); },
    };
    Object.defineProperty(navigator, 'credentials', {
      value: mockCredentials, writable: true, configurable: true,
    });
  });
}

test.describe('Profile & key storage (#110 Phase 5)', { tag: '@headless-adequate' }, () => {

  test('profile upsert updates in place on same host+port+username', async ({ page, mockSshServer }) => {
    await injectMockVault(page);
    await setupConnected(page, mockSshServer);

    // Save first profile
    await showTabBar(page);
    await clickConnectTab(page);
    await revealConnectForm(page);
    await page.locator('#profileName').fill('Original');
    await page.locator('#host').fill('upsert-host');
    await page.locator('#remote_a').fill('upsertuser');
    await page.locator('#remote_c').fill('pass1');
    await page.locator('#connectForm button[type="submit"]').click();
    await page.waitForTimeout(500);

    // Save again with same host+port+username but different name
    await showTabBar(page);
    await clickConnectTab(page);
    await revealConnectForm(page);
    await page.locator('#profileName').fill('Updated');
    await page.locator('#host').fill('upsert-host');
    await page.locator('#remote_a').fill('upsertuser');
    await page.locator('#remote_c').fill('pass2');
    await page.locator('#connectForm button[type="submit"]').click();
    await page.waitForTimeout(500);

    // Should have exactly 2 profiles (setupConnected saves one, we saved another unique host)
    // Actually setupConnected uses mock-host, so we have mock-host + upsert-host = 2
    const profiles = await page.evaluate(() => JSON.parse(localStorage.getItem('sshProfiles') || '[]'));
    const upsertProfiles = profiles.filter(p => p.host === 'upsert-host');
    expect(upsertProfiles.length).toBe(1);
    // #425 migrated profile.name → profile.title
    expect(upsertProfiles[0].title).toBe('Updated');
  });

  test('escHtml prevents script injection in profile names', async ({ page, mockSshServer }) => {
    await injectMockVault(page);
    await setupConnected(page, mockSshServer);

    // Save a profile with XSS payload in the name
    await showTabBar(page);
    await clickConnectTab(page);
    await revealConnectForm(page);
    await page.locator('#profileName').fill('<img src=x onerror=alert(1)>');
    await page.locator('#host').fill('xss-host');
    await page.locator('#remote_a').fill('xssuser');
    await page.locator('#remote_c').fill('xsspass');
    await page.locator('#connectForm button[type="submit"]').click();
    await page.waitForTimeout(500);

    // Navigate to connect panel to see profile list
    await showTabBar(page);
    await clickConnectTab(page);

    // The img tag should be escaped, not rendered as an element
    const imgCount = await page.locator('#profileList img').count();
    expect(imgCount).toBe(0);

    // The escaped text should be visible
    const profileHtml = await page.locator('#profileList').innerHTML();
    expect(profileHtml).toContain('&lt;img');
  });

  test('editing a profile reveals inline edit form populated with saved values', async ({ page, mockSshServer }) => {
    await injectMockVault(page);
    await setupConnected(page, mockSshServer);

    // Save a profile with all fields
    await showTabBar(page);
    await clickConnectTab(page);
    await revealConnectForm(page);
    await page.locator('#profileName').fill('LoadTest');
    await page.locator('#host').fill('load-host');
    await page.locator('#port').fill('2222');
    await page.locator('#remote_a').fill('loaduser');
    await page.locator('#remote_c').fill('loadpass');
    await page.locator('#connectForm button[type="submit"]').click();
    await page.waitForTimeout(500);

    // Return to connect panel
    await showTabBar(page);
    await clickConnectTab(page);

    // Clicking the profile item body no longer loads into the main form —
    // the profile list was refactored (#441 + inline-profile-edit) so that
    // editing is done via the Edit button, which expands an inline form
    // inside the .profile-item. Open that edit form and verify fields.
    const profileItem = page.locator('.profile-item', { hasText: 'loaduser@load-host' });
    await profileItem.waitFor({ state: 'visible', timeout: 3000 });
    await profileItem.locator('[data-action="edit"]').click();
    await page.waitForTimeout(300);

    // The inline edit form uses editTitle-<idx> ids. The idx depends on save
    // order — find the form within the matching item and read by data-field.
    const editForm = profileItem.locator('.profile-edit-form');
    await expect(editForm).toBeVisible({ timeout: 3000 });
    expect(await editForm.locator('[data-field="title"]').inputValue()).toBe('LoadTest');
    expect(await editForm.locator('[data-field="host"]').inputValue()).toBe('load-host');
    expect(await editForm.locator('[data-field="port"]').inputValue()).toBe('2222');
    expect(await editForm.locator('[data-field="username"]').inputValue()).toBe('loaduser');
  });

  test('deleting a profile removes it from localStorage', async ({ page, mockSshServer }) => {
    await injectMockVault(page);
    await setupConnected(page, mockSshServer);

    // Save a profile
    await showTabBar(page);
    await clickConnectTab(page);
    await revealConnectForm(page);
    await page.locator('#profileName').fill('ToDelete');
    await page.locator('#host').fill('delete-host');
    await page.locator('#remote_a').fill('deluser');
    await page.locator('#remote_c').fill('delpass');
    await page.locator('#connectForm button[type="submit"]').click();
    await page.waitForTimeout(500);

    const beforeCount = await page.evaluate(() =>
      JSON.parse(localStorage.getItem('sshProfiles') || '[]').length
    );

    // Delete via the delete button
    await showTabBar(page);
    await clickConnectTab(page);
    const deleteBtn = page.locator('.profile-item', { hasText: 'deluser@delete-host' })
      .locator('[data-action="delete"]');
    await deleteBtn.waitFor({ state: 'visible', timeout: 3000 });
    await deleteBtn.click();
    await page.waitForTimeout(300);

    const afterCount = await page.evaluate(() =>
      JSON.parse(localStorage.getItem('sshProfiles') || '[]').length
    );
    expect(afterCount).toBe(beforeCount - 1);

    // Profile should not exist in localStorage
    const remaining = await page.evaluate(() =>
      JSON.parse(localStorage.getItem('sshProfiles') || '[]')
    );
    expect(remaining.find(p => p.host === 'delete-host')).toBeUndefined();
  });

  test('key import rejects non-PEM data', async ({ page, mockSshServer }) => {
    await injectMockVault(page);
    await setupConnected(page, mockSshServer);

    // Keys tab was merged into Connect panel (#441 redirects #keys → #connect).
    // The "Stored Keys" <details> lives inside the Connect panel.
    await showTabBar(page);
    await clickConnectTab(page);
    await page.waitForTimeout(200);

    // Expand the Stored Keys <details> so the import form is visible.
    await page.evaluate(() => {
      const d = document.getElementById('keysSection');
      if (d && 'open' in d) d.open = true;
    });

    // Try to import invalid key data
    await page.locator('#keyName').fill('bad-key');
    await page.locator('#keyData').fill('this is not a PEM key');
    await page.locator('#importKeyBtn').click();
    await page.waitForTimeout(300);

    // Toast should show rejection message
    const toastText = await page.locator('#toast').textContent();
    expect(toastText).toContain('PEM');

    // No keys should be stored
    const keys = await page.evaluate(() => JSON.parse(localStorage.getItem('sshKeys') || '[]'));
    expect(keys.length).toBe(0);
  });

  test('empty hint shows when no profiles exist', async ({ page, mockSshServer }) => {
    // Don't use setupConnected — just navigate to a clean page
    await page.addInitScript(() => { localStorage.clear(); });
    await page.goto('./');
    await Promise.race([page.waitForSelector('#connectForm', { timeout: 8000 }), page.waitForSelector('.xterm-screen', { timeout: 8000 })]);

    await clickConnectTab(page);
    const hint = page.locator('#profileList .empty-hint');
    await expect(hint).toBeVisible();
    await expect(hint).toHaveText('No saved profiles yet.');
  });

});
