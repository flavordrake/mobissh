/**
 * tests/notifications.spec.js
 *
 * Terminal notification tests (#200).
 * Verifies that bell, OSC 9, and OSC 777 sequences trigger the Notification API
 * when termNotifications is enabled and permission is granted.
 */

const { test, expect, setupConnected } = require('./fixtures.js');

// Enable notifications and inject mock ServiceWorker + Notification API after page load.
// Must run after setupConnected (which navigates), since addInitScript
// localStorage gets wiped by the vault fixture's cancel flow.
async function enableNotifications(page) {
  await page.evaluate(() => {
    // Enable in localStorage
    localStorage.setItem('termNotifications', 'true');
    localStorage.setItem('notifBackgroundOnly', 'false');
    localStorage.setItem('notifCooldown', '1');

    // Mock Notification API (permission checks only — constructor not used in PWA)
    window.__notifications = [];
    Object.defineProperty(window, 'Notification', {
      value: { permission: 'granted', requestPermission: () => Promise.resolve('granted') },
      writable: true,
      configurable: true,
    });

    // Mock ServiceWorkerRegistration.showNotification
    const mockReg = {
      showNotification: (title, options) => {
        window.__notifications.push({ title, body: options?.body ?? '' });
        return Promise.resolve();
      },
    };
    if (!navigator.serviceWorker) {
      Object.defineProperty(navigator, 'serviceWorker', {
        value: { ready: Promise.resolve(mockReg) },
        configurable: true,
      });
    } else {
      Object.defineProperty(navigator.serviceWorker, 'ready', {
        value: Promise.resolve(mockReg),
        configurable: true,
      });
    }
  });
}

function getNotifications(page) {
  return page.evaluate(() => window.__notifications);
}

function clearNotifications(page) {
  return page.evaluate(() => { window.__notifications = []; });
}

test.describe('Terminal notifications (#200)', { tag: '@headless-adequate' }, () => {

  test('bell character triggers notification with terminal context', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableNotifications(page);

    // Send output followed by a bell
    mockSshServer.sendToPage({ type: 'output', data: 'build complete\r\n' });
    await page.waitForTimeout(100);
    mockSshServer.sendToPage({ type: 'output', data: '\x07' });
    await page.waitForTimeout(300);

    const notifs = await getNotifications(page);
    expect(notifs.length).toBeGreaterThanOrEqual(1);
    expect(notifs[0].title).toBe('MobiSSH');
    // Body should contain terminal context (the line near cursor)
    expect(notifs[0].body.length).toBeGreaterThan(0);
  });

  test('OSC 9 triggers notification with message', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableNotifications(page);

    // OSC 9 = \x1b]9;message\x07
    mockSshServer.sendToPage({ type: 'output', data: '\x1b]9;Deployment finished\x07' });
    await page.waitForTimeout(300);

    const notifs = await getNotifications(page);
    expect(notifs.length).toBe(1);
    expect(notifs[0].title).toBe('MobiSSH');
    expect(notifs[0].body).toBe('Deployment finished');
  });

  test('OSC 777 triggers notification with custom title and body', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableNotifications(page);

    // OSC 777 = \x1b]777;notify;Title;Body text\x07
    mockSshServer.sendToPage({ type: 'output', data: '\x1b]777;notify;Build Server;All tests passed\x07' });
    await page.waitForTimeout(300);

    const notifs = await getNotifications(page);
    expect(notifs.length).toBe(1);
    expect(notifs[0].title).toBe('Build Server');
    expect(notifs[0].body).toBe('All tests passed');
  });

  test('notifications do not fire when termNotifications is disabled', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableNotifications(page);

    // Disable notifications
    await page.evaluate(() => { localStorage.setItem('termNotifications', 'false'); });

    mockSshServer.sendToPage({ type: 'output', data: '\x07' });
    await page.waitForTimeout(300);

    const notifs = await getNotifications(page);
    expect(notifs.length).toBe(0);
  });

  test('notifications do not fire when permission is denied', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableNotifications(page);

    // Revoke permission
    await page.evaluate(() => {
      window.Notification = { permission: 'denied', requestPermission: () => Promise.resolve('denied') };
    });

    mockSshServer.sendToPage({ type: 'output', data: '\x1b]9;Should not appear\x07' });
    await page.waitForTimeout(300);

    const notifs = await getNotifications(page);
    expect(notifs.length).toBe(0);
  });

  test('background-only mode blocks notifications when page is visible', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableNotifications(page);

    // Enable background-only
    await page.evaluate(() => { localStorage.setItem('notifBackgroundOnly', 'true'); });

    mockSshServer.sendToPage({ type: 'output', data: '\x1b]9;Background test\x07' });
    await page.waitForTimeout(300);

    const notifs = await getNotifications(page);
    // Page is visible in headless tests, so background-only should block
    expect(notifs.length).toBe(0);
  });

  test('cooldown prevents rapid-fire notifications', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableNotifications(page);

    // Set a 5-second cooldown
    await page.evaluate(() => { localStorage.setItem('notifCooldown', '5000'); });

    // Fire two bells quickly
    mockSshServer.sendToPage({ type: 'output', data: '\x07' });
    await page.waitForTimeout(100);
    mockSshServer.sendToPage({ type: 'output', data: '\x07' });
    await page.waitForTimeout(300);

    const notifs = await getNotifications(page);
    // Only the first should fire; second is within cooldown
    expect(notifs.length).toBe(1);
  });
});

test.describe('Bell badge UI (#33)', { tag: '@headless-adequate' }, () => {

  test('bell icon hidden initially, shows with count after bell', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableNotifications(page);

    // Bell icon should be hidden initially
    const bellBtn = page.locator('#bellIndicatorBtn');
    await expect(bellBtn).toHaveClass(/hidden/);

    // Fire a bell
    mockSshServer.sendToPage({ type: 'output', data: 'done\r\n' });
    await page.waitForTimeout(100);
    mockSshServer.sendToPage({ type: 'output', data: '\x07' });
    await page.waitForTimeout(300);

    // Bell icon should now be visible with badge count 1
    await expect(bellBtn).not.toHaveClass(/hidden/);
    const badge = page.locator('#bellIndicatorBtn .bell-badge');
    await expect(badge).not.toHaveClass(/hidden/);
    await expect(badge).toHaveText('1');
  });

  test('badge increments on multiple bells', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableNotifications(page);

    mockSshServer.sendToPage({ type: 'output', data: '\x07' });
    await page.waitForTimeout(200);
    mockSshServer.sendToPage({ type: 'output', data: '\x07' });
    await page.waitForTimeout(200);
    mockSshServer.sendToPage({ type: 'output', data: '\x07' });
    await page.waitForTimeout(200);

    const badge = page.locator('#bellIndicatorBtn .bell-badge');
    await expect(badge).toHaveText('3');
  });

  test('OSC 9 increments badge', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableNotifications(page);

    mockSshServer.sendToPage({ type: 'output', data: '\x1b]9;First\x07' });
    await page.waitForTimeout(200);

    const badge = page.locator('#bellIndicatorBtn .bell-badge');
    await expect(badge).toHaveText('1');

    mockSshServer.sendToPage({ type: 'output', data: '\x1b]9;Second\x07' });
    await page.waitForTimeout(200);
    await expect(badge).toHaveText('2');
  });

  test('clear all resets badge and hides icon', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableNotifications(page);

    // Fire bells to get a badge
    mockSshServer.sendToPage({ type: 'output', data: '\x07' });
    await page.waitForTimeout(200);
    mockSshServer.sendToPage({ type: 'output', data: '\x07' });
    await page.waitForTimeout(200);

    const bellBtn = page.locator('#bellIndicatorBtn');
    await expect(bellBtn).not.toHaveClass(/hidden/);

    // Open drawer and clear
    await bellBtn.click();
    await page.waitForTimeout(100);
    await page.click('#notifClearAllBtn');
    await page.waitForTimeout(200);

    // Badge should be hidden, icon should be hidden
    await expect(bellBtn).toHaveClass(/hidden/);
  });
});

test.describe('Test notification button (#32)', { tag: '@headless-adequate' }, () => {

  test('test notification button uses ServiceWorker.showNotification', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Navigate to settings programmatically (tab may be obscured by terminal overlays)
    await page.evaluate(() => {
      document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
      document.querySelectorAll('.panel').forEach(p => p.classList.remove('active'));
      document.querySelector('[data-panel="settings"]')?.classList.add('active');
      document.getElementById('panel-settings')?.classList.add('active');
    });
    await page.waitForTimeout(200);

    // Set up SW mock and permission
    await enableNotifications(page);

    // Click the test notification button
    await page.click('#testNotifBtn');
    await page.waitForTimeout(500);

    const notifs = await getNotifications(page);
    expect(notifs.length).toBe(1);
    expect(notifs[0].title).toBe('MobiSSH');
    expect(notifs[0].body).toBe('Test notification');
  });

  test('test notification button shows error dialog on failure', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Navigate to settings programmatically
    await page.evaluate(() => {
      document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
      document.querySelectorAll('.panel').forEach(p => p.classList.remove('active'));
      document.querySelector('[data-panel="settings"]')?.classList.add('active');
      document.getElementById('panel-settings')?.classList.add('active');
    });
    await page.waitForTimeout(200);

    // Mock Notification with granted permission but SW that rejects
    await page.evaluate(() => {
      window.Notification = { permission: 'granted', requestPermission: () => Promise.resolve('granted') };
      const mockReg = {
        showNotification: () => Promise.reject(new Error('SW showNotification failed')),
      };
      Object.defineProperty(navigator.serviceWorker, 'ready', {
        value: Promise.resolve(mockReg),
        configurable: true,
      });
    });

    await page.click('#testNotifBtn');
    await page.waitForTimeout(500);

    // Error dialog should be visible with the error text
    const overlay = page.locator('#errorDialogOverlay');
    await expect(overlay).toBeVisible();

    const errorText = page.locator('#errorDialogText');
    await expect(errorText).toContainText('SW showNotification failed');

    // Dismiss should close it
    await page.click('#errorDialogDismiss');
    await expect(overlay).not.toBeVisible();
  });
});
