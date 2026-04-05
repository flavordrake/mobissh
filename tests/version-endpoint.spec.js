/**
 * tests/version-endpoint.spec.js
 *
 * Validates the /version endpoint and SSE /events channel.
 */

const { test, expect } = require('./fixtures.js');

const BASE_URL = (process.env.BASE_URL || 'http://localhost:8081').replace(/\/?$/, '/');

test.describe('Version and SSE endpoints', () => {

  test('/version returns JSON with version and hash', async ({ request }) => {
    const response = await request.get(BASE_URL + 'version');
    expect(response.ok()).toBe(true);
    expect(response.headers()['content-type']).toContain('json');

    const data = await response.json();
    expect(data).toHaveProperty('version');
    expect(data).toHaveProperty('hash');
    expect(typeof data.version).toBe('string');
    expect(typeof data.hash).toBe('string');
    expect(data.version).not.toBe('');
    expect(data.hash).not.toBe('');
  });

  test('/version has Cache-Control: no-store', async ({ request }) => {
    const response = await request.get(BASE_URL + 'version');
    expect(response.headers()['cache-control']).toBe('no-store');
  });

  test('/version hash matches app-version meta injected into HTML', async ({ page }) => {
    const versionRes = await page.request.get(BASE_URL + 'version');
    const serverData = await versionRes.json();

    await page.goto(BASE_URL);
    await Promise.race([
      page.waitForSelector('#connectForm', { timeout: 8000 }),
      page.waitForSelector('.xterm-screen', { timeout: 8000 }),
    ]);

    const metaContent = await page.evaluate(() => {
      const meta = document.querySelector('meta[name="app-version"]');
      return meta?.getAttribute('content') ?? '';
    });

    expect(metaContent).toContain(serverData.version);
    expect(metaContent).toContain(serverData.hash);
  });

  test('SSE /events connects and receives version event', async ({ page }) => {
    const logs = [];
    page.on('console', msg => {
      if (msg.text().includes('[sse]')) logs.push(msg.text());
    });

    await page.goto(BASE_URL);
    await Promise.race([
      page.waitForSelector('#connectForm', { timeout: 8000 }),
      page.waitForSelector('.xterm-screen', { timeout: 8000 }),
    ]);

    // Wait for SSE to connect and receive version event
    await page.waitForTimeout(2000);

    const connectedLog = logs.find(l => l.includes('[sse] connected'));
    expect(connectedLog).toBeTruthy();

    const freshLog = logs.find(l => l.includes('[sse] fresh'));
    expect(freshLog).toBeTruthy();
  });
});
