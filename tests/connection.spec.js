/**
 * tests/connection.spec.js
 *
 * Connection lifecycle — test gate for Phase 7 module extraction (#110).
 * Tests reconnect logic, disconnect cleanup, keepalive pings,
 * host key verification, and auth message construction.
 */

const { test, expect, setupConnected } = require('./fixtures.js');

test.describe('Connection lifecycle (#110 Phase 7)', () => {

  test('connect message includes host, port, username, and password', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    const connectMsg = mockSshServer.messages.find(m => m.type === 'connect');
    expect(connectMsg).toBeTruthy();
    expect(connectMsg.host).toBe('mock-host');
    expect(connectMsg.port).toBe(22);
    expect(connectMsg.username).toBe('testuser');
    expect(connectMsg.password).toBe('testpass');
  });

  test('resize message is sent after connection established', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    const resizeMsg = mockSshServer.messages.find(m => m.type === 'resize');
    expect(resizeMsg).toBeTruthy();
    expect(resizeMsg.cols).toBeGreaterThan(0);
    expect(resizeMsg.rows).toBeGreaterThan(0);
  });

  test('disconnect button sends disconnect message and resets status', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Session menu should show connected host
    const menuBtnBefore = await page.locator('#sessionMenuBtn').textContent();
    expect(menuBtnBefore).toContain('testuser@mock-host');

    // Open session menu and click disconnect
    await page.locator('#sessionMenuBtn').click();
    await page.locator('#sessionDisconnectBtn').click();
    await page.waitForTimeout(300);

    // Should have sent a disconnect message
    const disconnectMsg = mockSshServer.messages.find(m => m.type === 'disconnect');
    expect(disconnectMsg).toBeTruthy();

    // Session menu button should revert to default
    const menuBtnAfter = await page.locator('#sessionMenuBtn').textContent();
    expect(menuBtnAfter).toBe('MobiSSH');
  });

  test('keepalive does not send ping immediately after connect', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // The keepalive interval is 25s — verify no ping has been sent yet
    await page.waitForTimeout(200);
    const pings = mockSshServer.messages.filter(m => m.type === 'ping');
    expect(pings.length).toBe(0);
  });

  test('server disconnect triggers reconnect attempt', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    const connectCountBefore = mockSshServer.messages.filter(m => m.type === 'connect').length;

    // Simulate server-side disconnect
    mockSshServer.sendToPage({ type: 'disconnected', reason: 'test-reconnect' });

    // Wait for the reconnect timer to fire and a new connect message to arrive
    // Default reconnect delay is 2s (RECONNECT.INITIAL_DELAY_MS)
    await page.waitForFunction(() => {
      return (window.__mockWsSpy || []).filter(s => {
        try { return JSON.parse(s).type === 'connect'; } catch (_) { return false; }
      }).length > 1;
    }, null, { timeout: 10_000 });

    // A second connect message should have been sent
    const connectCountAfter = mockSshServer.messages.filter(m => m.type === 'connect').length;
    expect(connectCountAfter).toBeGreaterThan(connectCountBefore);
  });

  test('host key first-connect prompts user and stores on accept', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Send a hostkey message from the mock server
    mockSshServer.sendToPage({
      type: 'hostkey',
      host: 'hostkey-test',
      port: 22,
      keyType: 'ssh-ed25519',
      fingerprint: 'SHA256:abcdef1234567890',
    });

    // The host key overlay should appear
    const overlay = page.locator('#hostKeyOverlay');
    await expect(overlay).toBeVisible({ timeout: 3000 });

    // Should show the fingerprint and key type
    const overlayText = await overlay.textContent();
    expect(overlayText).toContain('SHA256:abcdef1234567890');
    expect(overlayText).toContain('ssh-ed25519');

    // Accept the key
    await page.locator('.hostkey-accept').click();
    await page.waitForTimeout(200);

    // Overlay should be dismissed
    await expect(overlay).not.toBeVisible();

    // Known hosts should be stored
    const knownHosts = await page.evaluate(() =>
      JSON.parse(localStorage.getItem('knownHosts') || '{}')
    );
    expect(knownHosts['hostkey-test:22']).toBeTruthy();
    expect(knownHosts['hostkey-test:22'].fingerprint).toBe('SHA256:abcdef1234567890');
  });

  test('host key mismatch shows warning with stored fingerprint', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Seed a known host AFTER page load (setupConnected clears localStorage)
    await page.evaluate(() => {
      localStorage.setItem('knownHosts', JSON.stringify({
        'mismatch-host:22': {
          fingerprint: 'SHA256:old-fingerprint',
          keyType: 'ssh-ed25519',
          addedAt: '2025-01-01T00:00:00Z',
        },
      }));
    });

    // Send hostkey with different fingerprint
    mockSshServer.sendToPage({
      type: 'hostkey',
      host: 'mismatch-host',
      port: 22,
      keyType: 'ssh-ed25519',
      fingerprint: 'SHA256:new-fingerprint',
    });

    const overlay = page.locator('#hostKeyOverlay');
    await expect(overlay).toBeVisible({ timeout: 3000 });

    // Should show MISMATCH warning
    const overlayText = await overlay.textContent();
    expect(overlayText).toContain('MISMATCH');
    expect(overlayText).toContain('SHA256:old-fingerprint');
    expect(overlayText).toContain('SHA256:new-fingerprint');
  });

  test('tab bar hides automatically on successful connection', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    const tabBarHidden = await page.locator('#tabBar').evaluate(el => el.classList.contains('hidden'));
    expect(tabBarHidden).toBe(true);
  });

  test('session menu shows connected host when connected', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    const menuBtnText = await page.locator('#sessionMenuBtn').textContent();
    expect(menuBtnText).toContain('testuser@mock-host');
  });

  test('host key reject does not store fingerprint', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    mockSshServer.sendToPage({
      type: 'hostkey',
      host: 'reject-host',
      port: 22,
      keyType: 'ssh-ed25519',
      fingerprint: 'SHA256:rejected-key',
    });

    const overlay = page.locator('#hostKeyOverlay');
    await expect(overlay).toBeVisible({ timeout: 3000 });

    // Reject the key
    await page.locator('.hostkey-reject').click();
    await page.waitForTimeout(200);

    // Overlay should be dismissed
    await expect(overlay).not.toBeVisible();

    // Known hosts should NOT contain the rejected key
    const knownHosts = await page.evaluate(() =>
      JSON.parse(localStorage.getItem('knownHosts') || '{}')
    );
    expect(knownHosts['reject-host:22']).toBeUndefined();

    // A hostkey_response with accepted=false should have been sent
    const response = mockSshServer.messages.find(
      m => m.type === 'hostkey_response' && m.accepted === false
    );
    expect(response).toBeTruthy();
  });

});
