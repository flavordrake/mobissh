/**
 * tests/notifications.spec.js
 *
 * Terminal notification tests (#200).
 * Verifies that bell, OSC 9, and OSC 777 sequences trigger the Notification API
 * when termNotifications is enabled and permission is granted.
 */

const { test, expect, setupConnected } = require('./fixtures.js');

// Enable notifications and inject mock Notification API after page load.
// Must run after setupConnected (which navigates), since addInitScript
// localStorage gets wiped by the vault fixture's cancel flow.
async function enableNotifications(page) {
  await page.evaluate(() => {
    // Enable in localStorage
    localStorage.setItem('termNotifications', 'true');
    localStorage.setItem('notifBackgroundOnly', 'false');
    localStorage.setItem('notifCooldown', '0');

    // Mock Notification API
    window.__notifications = [];
    window.Notification = class MockNotification {
      constructor(title, options) {
        window.__notifications.push({ title, body: options?.body ?? '' });
      }
    };
    Object.defineProperty(window.Notification, 'permission', {
      get: () => 'granted',
      configurable: true,
    });
    window.Notification.requestPermission = () => Promise.resolve('granted');
  });
}

function getNotifications(page) {
  return page.evaluate(() => window.__notifications);
}

function clearNotifications(page) {
  return page.evaluate(() => { window.__notifications = []; });
}

test.describe('Terminal notifications (#200)', () => {

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
      Object.defineProperty(window.Notification, 'permission', {
        get: () => 'denied',
        configurable: true,
      });
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
