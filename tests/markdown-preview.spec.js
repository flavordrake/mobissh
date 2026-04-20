/**
 * tests/markdown-preview.spec.js
 *
 * Integration test for markdown link/image rendering in the SFTP file preview.
 *
 * Unit tests in src/modules/__tests__/markdown-links.test.ts verify the
 * renderMarkdown string output. This test verifies the actual flow:
 * click a .md file → preview panel mounts → DOM has clickable <a> / <img>
 * elements with the correct hrefs / srcs.
 */

const { test, expect, setupConnected } = require('./fixtures.js');

const MARKDOWN_WITH_LINKS = [
  '# Project docs',
  '',
  'Diagrams: [docs/architecture/](docs/architecture/README.md).',
  'Transport: [permission-transport.md](docs/architecture/permission-transport.md).',
  '',
  'See also [external](https://example.com/page).',
  '',
  '![logo](./logo.png)',
  '',
  '```',
  '[not a link](./nope.md)',
  '```',
].join('\n');

const MOCK_ENTRIES = [
  { name: 'README.md', isDir: false, size: MARKDOWN_WITH_LINKS.length, mtime: 1710000000 },
  { name: 'notes.txt', isDir: false, size: 100, mtime: 1710100000 },
];

async function openFilesPanel(page) {
  // Session menu is opened by the MobiSSH button (#sessionMenuBtn), not the hamburger.
  await page.locator('#sessionMenuBtn').click();
  await expect(page.locator('#sessionMenu')).not.toHaveClass(/hidden/, { timeout: 3000 });
  await page.locator('#sessionFilesBtn').click();
  await expect(page.locator('#panel-files')).toHaveClass(/active/);
  await expect(page.locator('.files-breadcrumb')).toBeVisible({ timeout: 5000 });
}

function installSftpHandlersForPreview(mockSshServer, fileContent) {
  mockSshServer.onMessage = (ws, msg) => {
    if (msg.type === 'sftp_realpath') {
      ws.send(JSON.stringify({ type: 'sftp_realpath_result', requestId: msg.requestId, path: '/' }));
    } else if (msg.type === 'sftp_ls') {
      ws.send(JSON.stringify({ type: 'sftp_ls_result', requestId: msg.requestId, entries: MOCK_ENTRIES }));
    } else if (msg.type === 'sftp_download') {
      ws.send(JSON.stringify({
        type: 'sftp_download_result',
        requestId: msg.requestId,
        data: Buffer.from(fileContent).toString('base64'),
        ok: true,
      }));
    }
  };
}

test.describe('Markdown preview — link and image rendering', () => {
  test('renders [text](url) as real <a> tags with correct href', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    installSftpHandlersForPreview(mockSshServer, MARKDOWN_WITH_LINKS);
    await openFilesPanel(page);

    const mdEntry = page.locator('.files-entry[data-dir="false"]', { hasText: 'README.md' });
    await expect(mdEntry).toBeVisible({ timeout: 5000 });
    await mdEntry.click();

    const rendered = page.locator('.sftp-preview-panel .preview-rendered');
    await expect(rendered).toBeVisible({ timeout: 5000 });

    // Multiple real anchor tags, not literal "[text](url)" strings
    const links = rendered.locator('a');
    await expect(links).toHaveCount(3);

    // The clunky literal forms are gone
    await expect(rendered).not.toContainText('[docs/architecture/](docs/architecture/README.md)');
    await expect(rendered).not.toContainText('[permission-transport.md]');
    await expect(rendered).not.toContainText('[external](');

    // Href values are right
    await expect(rendered.locator('a', { hasText: 'external' }))
      .toHaveAttribute('href', 'https://example.com/page');
    await expect(rendered.locator('a', { hasText: 'docs/architecture/' }))
      .toHaveAttribute('href', 'docs/architecture/README.md');
    await expect(rendered.locator('a', { hasText: 'permission-transport.md' }))
      .toHaveAttribute('href', 'docs/architecture/permission-transport.md');

    // Only ABSOLUTE links (https://...) open in a new tab; relative links are
    // click-intercepted and should NOT have target/rel.
    const externalLink = rendered.locator('a', { hasText: 'external' });
    await expect(externalLink).toHaveAttribute('target', '_blank');
    await expect(externalLink).toHaveAttribute('rel', /noopener/);
    const relLink = rendered.locator('a', { hasText: 'docs/architecture/' });
    await expect(relLink).toHaveAttribute('data-sftp-relative', 'true');
  });

  test('renders ![alt](url) as <img> tag', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    installSftpHandlersForPreview(mockSshServer, MARKDOWN_WITH_LINKS);
    await openFilesPanel(page);

    await page.locator('.files-entry[data-dir="false"]', { hasText: 'README.md' }).click();
    const rendered = page.locator('.sftp-preview-panel .preview-rendered');
    await expect(rendered).toBeVisible({ timeout: 5000 });

    const img = rendered.locator('img');
    await expect(img).toHaveCount(1);
    await expect(img).toHaveAttribute('src', './logo.png');
    await expect(img).toHaveAttribute('alt', 'logo');

    // Literal markdown source for the image should not appear as text
    await expect(rendered).not.toContainText('![logo](./logo.png)');
  });

  test('links inside fenced code blocks are NOT rewritten', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    installSftpHandlersForPreview(mockSshServer, MARKDOWN_WITH_LINKS);
    await openFilesPanel(page);

    await page.locator('.files-entry[data-dir="false"]', { hasText: 'README.md' }).click();
    const rendered = page.locator('.sftp-preview-panel .preview-rendered');
    await expect(rendered).toBeVisible({ timeout: 5000 });

    // The fenced block contains literal `[not a link](./nope.md)` — should stay as text
    const codeBlock = rendered.locator('pre code');
    await expect(codeBlock).toContainText('[not a link](./nope.md)');

    // And no anchor was created for "not a link"
    await expect(rendered.locator('a', { hasText: 'not a link' })).toHaveCount(0);
  });

  test('clicking a relative link re-enters SFTP preview for the resolved path', async ({ page, mockSshServer }) => {
    const parentMd = '# Parent\n\nSee [the child](./child.md).';
    const childMd = '# Child\n\nLeaf content.';
    const downloadRequests = [];

    // Install handler that records requested paths and serves different content per path.
    mockSshServer.onMessage = (ws, msg) => {
      if (msg.type === 'sftp_realpath') {
        ws.send(JSON.stringify({ type: 'sftp_realpath_result', requestId: msg.requestId, path: '/docs' }));
      } else if (msg.type === 'sftp_ls') {
        ws.send(JSON.stringify({
          type: 'sftp_ls_result',
          requestId: msg.requestId,
          entries: [
            { name: 'README.md', isDir: false, size: parentMd.length, mtime: 1710000000 },
            { name: 'child.md', isDir: false, size: childMd.length, mtime: 1710100000 },
          ],
        }));
      } else if (msg.type === 'sftp_download') {
        downloadRequests.push(msg.path);
        const body = msg.path.endsWith('/child.md') ? childMd : parentMd;
        ws.send(JSON.stringify({
          type: 'sftp_download_result',
          requestId: msg.requestId,
          data: Buffer.from(body).toString('base64'),
          ok: true,
        }));
      }
    };

    await setupConnected(page, mockSshServer);
    await openFilesPanel(page);

    // Open parent
    await page.locator('.files-entry[data-dir="false"]', { hasText: 'README.md' }).click();
    const rendered = page.locator('.sftp-preview-panel .preview-rendered');
    await expect(rendered).toBeVisible({ timeout: 5000 });
    await expect(rendered.locator('h1', { hasText: 'Parent' })).toBeVisible();

    // Click the relative link
    await rendered.locator('a[data-sftp-relative="true"]', { hasText: 'the child' }).click();

    // Should re-download for resolved path and show child content
    await expect(rendered.locator('h1', { hasText: 'Child' })).toBeVisible({ timeout: 5000 });
    expect(downloadRequests).toEqual(['/docs/README.md', '/docs/child.md']);
  });

  test('javascript: href is NOT created (stripped to literal text)', async ({ page, mockSshServer }) => {
    const hostile = '# Hostile\n\nClick [me](javascript:alert(1)).';
    await setupConnected(page, mockSshServer);
    installSftpHandlersForPreview(mockSshServer, hostile);
    await openFilesPanel(page);

    await page.locator('.files-entry[data-dir="false"]', { hasText: 'README.md' }).click();
    const rendered = page.locator('.sftp-preview-panel .preview-rendered');
    await expect(rendered).toBeVisible({ timeout: 5000 });

    // No anchor with javascript: href
    const anchors = rendered.locator('a');
    const hrefs = await anchors.evaluateAll(nodes => nodes.map(n => n.getAttribute('href') ?? ''));
    expect(hrefs.every(h => !h.toLowerCase().startsWith('javascript:'))).toBe(true);

    // The literal markdown text remains
    await expect(rendered).toContainText('[me](javascript:');
  });
});
