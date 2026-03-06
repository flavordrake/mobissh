/**
 * tests/panels.spec.js
 *
 * Smoke tests for top-level panel navigation and Files panel basic flow.
 *
 * Tab navigation smoke
 * ─────────────────────
 * Clicks each top-level tab (Terminal, Connect, Files, Keys, Settings) and
 * verifies the correct panel activates without console errors.
 *
 * Files panel flow
 * ─────────────────
 * Connects to the mockSshServer, navigates to the Files tab, and drives the
 * sftp_realpath + sftp_ls exchange via the mock WS fixture, verifying that
 * directory entries render. Also verifies no console.error fires with
 * "Unknown message type" during the full flow.
 */

const { test, expect, setupConnected } = require('./fixtures.js');

// Show the tab bar (auto-hidden on successful SSH connection, see #36).
async function showTabBar(page) {
  await page.locator('#sessionMenuBtn').click();
  await page.locator('#sessionNavBarBtn').click();
  await page.waitForSelector('#tabBar:not(.hidden)', { timeout: 2000 });
}

test.describe('Panel navigation smoke', () => {

  test('all tabs render their panel without console errors (no connection)', async ({ page }) => {
    const consoleErrors = [];
    page.on('console', (msg) => {
      if (msg.type() === 'error') consoleErrors.push(msg.text());
    });

    await page.addInitScript(() => { localStorage.clear(); });
    await page.goto('./');
    await page.waitForSelector('.xterm-screen', { timeout: 8000 });

    // Terminal is the default active panel
    await expect(page.locator('#panel-terminal')).toHaveClass(/active/);

    // Connect tab
    await page.locator('[data-panel="connect"]').click();
    await expect(page.locator('#panel-connect')).toHaveClass(/active/);

    // Settings tab
    await page.locator('[data-panel="settings"]').click();
    await expect(page.locator('#panel-settings')).toHaveClass(/active/);

    // Keys tab
    await page.locator('[data-panel="keys"]').click();
    await expect(page.locator('#panel-keys')).toHaveClass(/active/);

    // Files tab — panel activates; sftp_realpath is silently dropped (not connected)
    await page.locator('[data-panel="files"]').click();
    await expect(page.locator('#panel-files')).toHaveClass(/active/);

    // Terminal tab
    await page.locator('[data-panel="terminal"]').click();
    await expect(page.locator('#panel-terminal')).toHaveClass(/active/);

    const unknownMsgErrors = consoleErrors.filter((e) => e.includes('Unknown message type'));
    expect(unknownMsgErrors).toHaveLength(0);
  });

});

test.describe('Files panel', () => {

  test('shows loading state without errors when not connected', async ({ page }) => {
    const consoleErrors = [];
    page.on('console', (msg) => {
      if (msg.type() === 'error') consoleErrors.push(msg.text());
    });

    await page.addInitScript(() => { localStorage.clear(); });
    await page.goto('./');
    await page.waitForSelector('.xterm-screen', { timeout: 8000 });

    await page.locator('[data-panel="files"]').click();
    await expect(page.locator('#panel-files')).toHaveClass(/active/);

    // sendSftpRealpath guard returns early when not connected — no WS traffic, no errors
    await page.waitForTimeout(300);
    const unknownMsgErrors = consoleErrors.filter((e) => e.includes('Unknown message type'));
    expect(unknownMsgErrors).toHaveLength(0);
  });

  test('renders directory listing via sftp_realpath + sftp_ls after connection', async ({ page, mockSshServer }) => {
    const consoleErrors = [];
    page.on('console', (msg) => {
      if (msg.type() === 'error') consoleErrors.push(msg.text());
    });

    await setupConnected(page, mockSshServer);

    // Show tab bar (auto-hidden on successful connection)
    await showTabBar(page);

    // Navigate to Files tab
    await page.locator('[data-panel="files"]').click();
    await expect(page.locator('#panel-files')).toHaveClass(/active/);

    // Wait for the app to send sftp_realpath to the mock server
    await page.waitForFunction(
      () => (window.__mockWsSpy || []).some((s) => {
        try { return JSON.parse(s).type === 'sftp_realpath'; } catch (_) { return false; }
      }),
      null,
      { timeout: 5000 },
    );

    // Reply with the home directory path
    const realpathMsg = mockSshServer.messages.find((m) => m.type === 'sftp_realpath');
    expect(realpathMsg).toBeTruthy();
    mockSshServer.sendToPage({
      type: 'sftp_realpath_result',
      requestId: realpathMsg.requestId,
      path: '/home/testuser',
    });

    // Wait for the app to request the directory listing
    await page.waitForFunction(
      () => (window.__mockWsSpy || []).some((s) => {
        try { return JSON.parse(s).type === 'sftp_ls'; } catch (_) { return false; }
      }),
      null,
      { timeout: 5000 },
    );

    // Reply with a mock directory listing
    const lsMsg = mockSshServer.messages.find((m) => m.type === 'sftp_ls');
    expect(lsMsg).toBeTruthy();
    mockSshServer.sendToPage({
      type: 'sftp_ls_result',
      requestId: lsMsg.requestId,
      entries: [
        { name: '.bashrc',   isDir: false, isSymlink: false, size: 3526, mtime: '1700000000', atime: '1700000000', permissions: 0o100644, uid: 1000, gid: 1000 },
        { name: 'projects',  isDir: true,  isSymlink: false, size: 4096, mtime: '1700000000', atime: '1700000000', permissions: 0o040755, uid: 1000, gid: 1000 },
        { name: 'readme.md', isDir: false, isSymlink: false, size: 512,  mtime: '1700000000', atime: '1700000000', permissions: 0o100644, uid: 1000, gid: 1000 },
      ],
    });

    // Wait for the file entries to render
    await page.waitForSelector('.files-entry', { timeout: 5000 });

    const entryCount = await page.locator('.files-entry').count();
    expect(entryCount).toBeGreaterThanOrEqual(1);

    // Breadcrumb should reflect the home path
    const breadcrumbText = await page.locator('.files-breadcrumb').textContent();
    expect(breadcrumbText).toContain('testuser');

    // No "Unknown message type" errors during the full flow
    const unknownMsgErrors = consoleErrors.filter((e) => e.includes('Unknown message type'));
    expect(unknownMsgErrors).toHaveLength(0);
  });

});
