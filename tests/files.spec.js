/**
 * tests/files.spec.js
 *
 * SFTP Files panel UI and upload resilience tests (#209).
 *
 * These tests verify the Files panel: Explore/Transfer sub-tabs, directory
 * browsing, file selection, transfer direction indicators, and upload flow.
 * Uses the mockSshServer fixture with SFTP message handling bolted on.
 */

const { test, expect, setupConnected } = require('./fixtures.js');

// Mock directory listing for SFTP responses
const MOCK_ROOT_ENTRIES = [
  { name: 'Documents', isDir: true, size: 0, mtime: 1710000000 },
  { name: 'photos', isDir: true, size: 0, mtime: 1710100000 },
  { name: 'readme.txt', isDir: false, size: 1234, mtime: 1710200000 },
  { name: 'data.csv', isDir: false, size: 56789, mtime: 1710300000 },
];

const MOCK_DOCS_ENTRIES = [
  { name: 'notes', isDir: true, size: 0, mtime: 1710050000 },
  { name: 'report.pdf', isDir: false, size: 204800, mtime: 1710150000 },
];

/**
 * Show the tab bar (hidden after setupConnected) and navigate to Files tab.
 * The mock server must handle sftp_realpath and sftp_ls messages.
 */
async function openSessionMenu(page) {
  // Files is now reached via the session menu (#449). Hamburger opens the menu.
  await page.locator('#handleMenuBtn').click();
  await expect(page.locator('#sessionMenu')).not.toHaveClass(/hidden/, { timeout: 3000 });
}

async function navigateToFiles(page) {
  await openSessionMenu(page);
  await page.locator('#sessionFilesBtn').click();
  await expect(page.locator('#panel-files')).toHaveClass(/active/);
  // Wait for the files panel to render breadcrumb (from sftp_ls_result)
  await expect(page.locator('.files-breadcrumb')).toBeVisible({ timeout: 5000 });
}

/**
 * Install SFTP message handlers on the mock WS server.
 * Uses the fixture's onMessage callback to handle SFTP protocol messages
 * alongside the existing connect/output flow.
 */
function installSftpHandlers(mockSshServer) {
  mockSshServer.onMessage = (ws, msg) => {
    if (msg.type === 'sftp_realpath') {
      ws.send(JSON.stringify({
        type: 'sftp_realpath_result',
        requestId: msg.requestId,
        path: '/'
      }));
    } else if (msg.type === 'sftp_ls') {
      const entries = msg.path === '/' ? MOCK_ROOT_ENTRIES :
                      msg.path === '/Documents' ? MOCK_DOCS_ENTRIES : [];
      ws.send(JSON.stringify({
        type: 'sftp_ls_result',
        requestId: msg.requestId,
        entries
      }));
    } else if (msg.type === 'sftp_upload_start') {
      ws.send(JSON.stringify({
        type: 'sftp_upload_ack',
        requestId: msg.requestId,
        offset: 0
      }));
    } else if (msg.type === 'sftp_upload_chunk') {
      ws.send(JSON.stringify({
        type: 'sftp_upload_ack',
        requestId: msg.requestId,
        offset: msg.offset
      }));
    } else if (msg.type === 'sftp_upload_end') {
      ws.send(JSON.stringify({
        type: 'sftp_upload_result',
        requestId: msg.requestId,
        ok: true
      }));
    } else if (msg.type === 'sftp_download') {
      ws.send(JSON.stringify({
        type: 'sftp_download_result',
        requestId: msg.requestId,
        data: Buffer.from('mock file content').toString('base64'),
        ok: true
      }));
    }
  };
}

// ── Explore tab basics ──────────────────────────────────────────────────────

test.describe('Files panel Explore tab (#209)', () => {
  test('renders with Explore and Transfer sub-tabs', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    installSftpHandlers(mockSshServer);

    // Show tab bar (hidden after connect) and navigate to Files tab
    await openSessionMenu(page);
    await page.locator('#sessionFilesBtn').click();
    await expect(page.locator('#panel-files')).toHaveClass(/active/);

    // Sub-tabs should be visible
    const exploreTab = page.locator('.files-subtab[data-subtab="explore"]');
    const transferTab = page.locator('.files-subtab[data-subtab="transfer"]');
    await expect(exploreTab).toBeVisible();
    await expect(transferTab).toBeVisible();
    await expect(exploreTab).toHaveText('Explore');
    await expect(transferTab).toHaveText(/Transfer/);
  });

  test('breadcrumb shows current path after directory loads', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    installSftpHandlers(mockSshServer);

    await navigateToFiles(page);

    // Breadcrumb should show root path
    const breadcrumb = page.locator('.files-breadcrumb');
    await expect(breadcrumb).toBeVisible();
    // Root crumb is "/"
    await expect(breadcrumb.locator('.files-crumb').first()).toHaveText('/');
  });

  test('directory entries show D icon, file entries show F icon', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    installSftpHandlers(mockSshServer);

    await navigateToFiles(page);
    // Wait for file entries to appear
    await expect(page.locator('.files-entry').first()).toBeVisible({ timeout: 5000 });

    // Directory entries have data-dir="true" and icon D
    const dirEntries = page.locator('.files-entry[data-dir="true"]');
    await expect(dirEntries).toHaveCount(2); // Documents, photos
    const dirIcon = dirEntries.first().locator('.files-entry-icon');
    await expect(dirIcon).toHaveText('D');

    // File entries have data-dir="false" and icon F
    const fileEntries = page.locator('.files-entry[data-dir="false"]');
    await expect(fileEntries).toHaveCount(2); // readme.txt, data.csv
    const fileIcon = fileEntries.first().locator('.files-entry-icon');
    await expect(fileIcon).toHaveText('F');
  });

  test('tapping a directory navigates into it and updates breadcrumb', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    installSftpHandlers(mockSshServer);

    await navigateToFiles(page);
    await expect(page.locator('.files-entry').first()).toBeVisible({ timeout: 5000 });

    // Click the Documents directory
    const docsEntry = page.locator('.files-entry[data-dir="true"]', { hasText: 'Documents' });
    await docsEntry.click();

    // Breadcrumb should update to show Documents
    await expect(page.locator('.files-breadcrumb')).toContainText('Documents');

    // Should show Documents contents
    await expect(page.locator('.files-entry', { hasText: 'report.pdf' })).toBeVisible({ timeout: 5000 });
  });
});

// ── File selection ──────────────────────────────────────────────────────────

test.describe('Files panel file selection (#209)', () => {
  test('single tap on file toggles files-selected class', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    installSftpHandlers(mockSshServer);

    await navigateToFiles(page);
    await expect(page.locator('.files-entry').first()).toBeVisible({ timeout: 5000 });

    // Click a file entry
    const fileEntry = page.locator('.files-entry[data-dir="false"]').first();
    await fileEntry.click();
    await expect(fileEntry).toHaveClass(/files-selected/);

    // Click again to deselect
    await fileEntry.click();
    await expect(fileEntry).not.toHaveClass(/files-selected/);
  });

  test('single tap on folder navigates, does NOT select', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    installSftpHandlers(mockSshServer);

    await navigateToFiles(page);
    await expect(page.locator('.files-entry').first()).toBeVisible({ timeout: 5000 });

    const dirEntry = page.locator('.files-entry[data-dir="true"]').first();
    await dirEntry.click();

    // Should navigate (breadcrumb updates), not just select
    await expect(page.locator('.files-breadcrumb')).not.toHaveText('/', { timeout: 3000 });
  });

  test('download button appears with count when files selected, hides when deselected', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    installSftpHandlers(mockSshServer);

    await navigateToFiles(page);
    await expect(page.locator('.files-entry').first()).toBeVisible({ timeout: 5000 });

    const dlBtn = page.locator('.files-download-btn');

    // Initially hidden
    await expect(dlBtn).toHaveClass(/hidden/);

    // Select first file
    const file1 = page.locator('.files-entry[data-dir="false"]').first();
    await file1.click();

    // Download button visible with count
    await expect(dlBtn).not.toHaveClass(/hidden/);
    await expect(dlBtn).toHaveText(/Download \(1\)/);

    // Select second file
    const file2 = page.locator('.files-entry[data-dir="false"]').nth(1);
    await file2.click();
    await expect(dlBtn).toHaveText(/Download \(2\)/);

    // Deselect both
    await file1.click();
    await file2.click();
    await expect(dlBtn).toHaveClass(/hidden/);
  });
});

// ── Transfer tab ────────────────────────────────────────────────────────────

test.describe('Files panel Transfer tab (#209)', () => {
  test('switching to Transfer tab shows transfer list', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    installSftpHandlers(mockSshServer);

    await openSessionMenu(page);
    await page.locator('#sessionFilesBtn').click();
    await expect(page.locator('#panel-files')).toHaveClass(/active/);

    // Click Transfer sub-tab
    const transferTab = page.locator('.files-subtab[data-subtab="transfer"]');
    await transferTab.click();

    // Transfer view should be visible, Explore hidden
    await expect(page.locator('#filesTransfer')).not.toHaveClass(/hidden/);
    await expect(page.locator('#filesExplore')).toHaveClass(/hidden/);

    // Transfer list should exist
    await expect(page.locator('#transferList')).toBeVisible();
  });

  test('upload button in Transfer tab exists', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    installSftpHandlers(mockSshServer);

    await openSessionMenu(page);
    await page.locator('#sessionFilesBtn').click();
    await expect(page.locator('#panel-files')).toHaveClass(/active/);

    // Switch to Transfer tab
    await page.locator('.files-subtab[data-subtab="transfer"]').click();

    // Upload button should be present
    const uploadBtn = page.locator('#transferUploadBtn');
    await expect(uploadBtn).toBeVisible();
    await expect(uploadBtn).toHaveText('Upload Files');
  });
});

// ── Upload flow ─────────────────────────────────────────────────────────────

test.describe('Files panel upload flow (#209)', () => {
  test('upload sends sftp_upload_start message via WS', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    installSftpHandlers(mockSshServer);

    await navigateToFiles(page);
    await expect(page.locator('.files-entry').first()).toBeVisible({ timeout: 5000 });

    // Use page.setInputFiles on the hidden file input to simulate upload
    const fileInput = page.locator('#filesExplore .files-upload-input');

    // Create a small test file
    await fileInput.setInputFiles({
      name: 'test-upload.txt',
      mimeType: 'text/plain',
      buffer: Buffer.from('hello world test content'),
    });

    // Wait for the WS spy to capture the sftp_upload_start message
    const hasUploadStart = await page.waitForFunction(() => {
      return (window.__mockWsSpy || []).some((s) => {
        try { return JSON.parse(s).type === 'sftp_upload_start'; } catch { return false; }
      });
    }, null, { timeout: 5000 });
    expect(hasUploadStart).toBeTruthy();

    // Verify the message contents
    const uploadStartMsg = await page.evaluate(() => {
      const spy = window.__mockWsSpy || [];
      for (const s of spy) {
        try {
          const m = JSON.parse(s);
          if (m.type === 'sftp_upload_start') return m;
        } catch { /* skip */ }
      }
      return null;
    });
    expect(uploadStartMsg).not.toBeNull();
    expect(uploadStartMsg.path).toContain('test-upload.txt');
    expect(uploadStartMsg.size).toBeGreaterThan(0);
  });

  test('upload completion marks transfer as done with checkmark', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    installSftpHandlers(mockSshServer);

    await navigateToFiles(page);
    await expect(page.locator('.files-entry').first()).toBeVisible({ timeout: 5000 });

    // Upload a file
    const fileInput = page.locator('#filesExplore .files-upload-input');
    await fileInput.setInputFiles({
      name: 'complete-test.txt',
      mimeType: 'text/plain',
      buffer: Buffer.from('completed file'),
    });

    // Wait for upload to complete and switch to Transfer tab to see the result
    await page.waitForFunction(() => {
      return (window.__mockWsSpy || []).some((s) => {
        try { return JSON.parse(s).type === 'sftp_upload_end'; } catch { return false; }
      });
    }, null, { timeout: 10000 });

    // Switch to Transfer tab
    await page.locator('.files-subtab[data-subtab="transfer"]').click();
    await expect(page.locator('#filesTransfer')).not.toHaveClass(/hidden/);

    // Check for the checkmark (done status uses Unicode check mark)
    await expect(page.locator('.transfer-item-pct', { hasText: '\u2713' })).toBeVisible({ timeout: 5000 });
  });

  test('download failure marks transfer as failed with X mark', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Install SFTP handlers that return error for download requests
    mockSshServer.onMessage = (ws, msg) => {
      if (msg.type === 'sftp_realpath') {
        ws.send(JSON.stringify({ type: 'sftp_realpath_result', requestId: msg.requestId, path: '/' }));
      } else if (msg.type === 'sftp_ls') {
        ws.send(JSON.stringify({ type: 'sftp_ls_result', requestId: msg.requestId, entries: MOCK_ROOT_ENTRIES }));
      } else if (msg.type === 'sftp_download') {
        // Respond with an error to trigger the failure path
        ws.send(JSON.stringify({ type: 'sftp_error', requestId: msg.requestId, message: 'Permission denied' }));
      }
    };

    await navigateToFiles(page);
    await expect(page.locator('.files-entry').first()).toBeVisible({ timeout: 5000 });

    // Select a file and click Download
    const fileEntry = page.locator('.files-entry[data-dir="false"]').first();
    await fileEntry.click();
    await expect(fileEntry).toHaveClass(/files-selected/);

    const dlBtn = page.locator('.files-download-btn');
    await expect(dlBtn).not.toHaveClass(/hidden/);
    await dlBtn.click();

    // Switch to Transfer tab and look for failure indicator (X mark)
    await page.locator('.files-subtab[data-subtab="transfer"]').click();
    await expect(page.locator('.transfer-item-pct', { hasText: '\u2717' })).toBeVisible({ timeout: 5000 });
  });
});

// ── Direction indicators ────────────────────────────────────────────────────

test.describe('Files panel transfer direction indicators (#209)', () => {
  test('upload transfers show up-arrow with upload direction class', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    installSftpHandlers(mockSshServer);

    await navigateToFiles(page);
    await expect(page.locator('.files-entry').first()).toBeVisible({ timeout: 5000 });

    // Upload a file
    const fileInput = page.locator('#filesExplore .files-upload-input');
    await fileInput.setInputFiles({
      name: 'direction-test.txt',
      mimeType: 'text/plain',
      buffer: Buffer.from('direction indicator test'),
    });

    // Wait for upload to complete
    await page.waitForFunction(() => {
      return (window.__mockWsSpy || []).some((s) => {
        try { return JSON.parse(s).type === 'sftp_upload_end'; } catch { return false; }
      });
    }, null, { timeout: 10000 });

    // Switch to Transfer tab
    await page.locator('.files-subtab[data-subtab="transfer"]').click();
    await expect(page.locator('#filesTransfer')).not.toHaveClass(/hidden/);

    // Upload arrow should be present with upload class
    const dirIndicator = page.locator('.transfer-direction-upload');
    await expect(dirIndicator).toBeVisible({ timeout: 5000 });
    await expect(dirIndicator).toHaveText('\u2191'); // up arrow
  });

  test('download transfers show down-arrow with download direction class', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    installSftpHandlers(mockSshServer);

    await navigateToFiles(page);
    await expect(page.locator('.files-entry').first()).toBeVisible({ timeout: 5000 });

    // Select a file and click Download to trigger download transfer
    const fileEntry = page.locator('.files-entry[data-dir="false"]').first();
    await fileEntry.click();
    await expect(fileEntry).toHaveClass(/files-selected/);

    const dlBtn = page.locator('.files-download-btn');
    await expect(dlBtn).not.toHaveClass(/hidden/);
    await dlBtn.click();

    // Switch to Transfer tab
    await page.locator('.files-subtab[data-subtab="transfer"]').click();
    await expect(page.locator('#filesTransfer')).not.toHaveClass(/hidden/);

    // Download arrow should be present with download class
    const dirIndicator = page.locator('.transfer-direction-download');
    await expect(dirIndicator).toBeVisible({ timeout: 5000 });
    await expect(dirIndicator).toHaveText('\u2193'); // down arrow
  });
});
