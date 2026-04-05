/**
 * tests/version-endpoint.spec.js
 *
 * Validates the /version endpoint used for client-side cache freshness checks.
 */

const { test, expect } = require('./fixtures.js');

const BASE_URL = (process.env.BASE_URL || 'http://localhost:8081').replace(/\/?$/, '/');

test.describe('Version endpoint', () => {

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
    // Get the version from the endpoint
    const versionRes = await page.request.get(BASE_URL + 'version');
    const serverData = await versionRes.json();

    // Load the app and read the injected meta tag
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

  test('version freshness check logs fresh on matching version', async ({ page }) => {
    const logs = [];
    page.on('console', msg => {
      if (msg.text().includes('[version]')) logs.push(msg.text());
    });

    await page.goto(BASE_URL);
    await Promise.race([
      page.waitForSelector('#connectForm', { timeout: 8000 }),
      page.waitForSelector('.xterm-screen', { timeout: 8000 }),
    ]);

    // Wait for async version check to complete
    await page.waitForTimeout(2000);

    const freshLog = logs.find(l => l.includes('[version] fresh'));
    expect(freshLog).toBeTruthy();
  });
});
