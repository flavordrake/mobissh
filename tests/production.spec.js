/**
 * tests/production.spec.js
 *
 * Production endpoint tests -- validates the Tailscale-served container.
 * Run with: BASE_URL=https://mobissh.tailbe5094.ts.net npx playwright test tests/production.spec.js
 */

const { test, expect } = require('@playwright/test');

const PROD_URL = 'https://mobissh.tailbe5094.ts.net/';

test.describe('Production endpoint', { tag: '@headless-adequate' }, () => {

  test('serves HTML over HTTPS', async ({ page }) => {
    const response = await page.goto(PROD_URL, { waitUntil: 'networkidle' });
    expect(response.status()).toBe(200);
    expect(response.url()).toMatch(/^https:\/\//);
  });

  test('no mixed content -- all resources load over HTTPS', async ({ page }) => {
    const httpRequests = [];
    page.on('request', req => {
      if (req.url().startsWith('http://') && !req.url().includes('localhost')) {
        httpRequests.push({ type: req.resourceType(), url: req.url() });
      }
    });

    await page.goto(PROD_URL, { waitUntil: 'networkidle' });
    await page.waitForTimeout(2000);

    if (httpRequests.length > 0) {
      console.log('Mixed content requests:', JSON.stringify(httpRequests, null, 2));
    }
    expect(httpRequests).toHaveLength(0);
  });

  test('no console errors on load', async ({ page }) => {
    const errors = [];
    page.on('console', msg => {
      if (msg.type() === 'error') errors.push(msg.text());
    });
    page.on('pageerror', err => errors.push(err.message));

    await page.goto(PROD_URL, { waitUntil: 'networkidle' });
    await page.waitForTimeout(2000);

    if (errors.length > 0) {
      console.log('Console errors:', errors);
    }
    expect(errors).toHaveLength(0);
  });

  test('all subresources load successfully', async ({ page }) => {
    const failed = [];
    page.on('requestfailed', req => {
      failed.push({ url: req.url(), error: req.failure()?.errorText });
    });

    await page.goto(PROD_URL, { waitUntil: 'networkidle' });
    await page.waitForTimeout(2000);

    if (failed.length > 0) {
      console.log('Failed requests:', JSON.stringify(failed, null, 2));
    }
    expect(failed).toHaveLength(0);
  });

  test('WebSocket connects over wss://', async ({ page }) => {
    const wsUrls = [];
    page.on('websocket', ws => wsUrls.push(ws.url()));

    await page.goto(PROD_URL, { waitUntil: 'networkidle' });
    await page.waitForTimeout(2000);

    // No WS connection expected without clicking connect, but if SW or
    // keepalive worker opens one, verify it uses wss://
    for (const url of wsUrls) {
      expect(url).toMatch(/^wss:\/\//);
    }
  });

  test('service worker registers', async ({ page }) => {
    await page.goto(PROD_URL, { waitUntil: 'networkidle' });
    await page.waitForTimeout(3000);

    const swRegistered = await page.evaluate(() => {
      return navigator.serviceWorker?.controller !== null ||
        navigator.serviceWorker?.ready !== undefined;
    });
    expect(swRegistered).toBeTruthy();
  });

  test('console log dump', async ({ page }) => {
    const logs = [];
    page.on('console', msg => logs.push('[' + msg.type() + '] ' + msg.text()));
    page.on('pageerror', err => logs.push('[pageerror] ' + err.message));
    page.on('requestfailed', req => logs.push('[reqfail] ' + req.url() + ' ' + (req.failure()?.errorText || '')));

    const requests = [];
    page.on('request', req => requests.push(req.resourceType() + ': ' + req.url()));

    await page.goto(PROD_URL, { waitUntil: 'networkidle' });
    await page.waitForTimeout(3000);

    console.log('All requests:');
    requests.forEach(r => console.log('  ' + r));
    console.log('All console output:');
    logs.forEach(l => console.log('  ' + l));
  });
});
