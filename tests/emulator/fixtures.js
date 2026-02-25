/**
 * tests/emulator/fixtures.js
 *
 * Playwright fixtures for Android emulator testing over CDP.
 *
 * Connects to real Chrome on the emulator via ADB-forwarded DevTools port.
 * A single CDP connection is held for the entire worker (all tests in a file),
 * and each test gets a fresh tab with cleared localStorage.
 *
 * Usage:
 *   const { test, expect, screenshot } = require('./fixtures');
 *   test('my test', async ({ emulatorPage }) => { ... });
 */

const { test: base, expect } = require('@playwright/test');
const { chromium } = require('@playwright/test');
const { execSync } = require('child_process');

const CDP_PORT = Number(process.env.CDP_PORT || 9222);
const BASE_URL = process.env.BASE_URL || 'http://localhost:8081';

/**
 * Ensure ADB is forwarding the Chrome DevTools port from the emulator.
 * Idempotent — safe to call multiple times.
 */
function ensureAdbForward() {
  try {
    const existing = execSync('adb forward --list', { encoding: 'utf8' });
    if (existing.includes(`tcp:${CDP_PORT}`)) return;
  } catch { /* adb not forwarded yet */ }

  execSync(`adb forward tcp:${CDP_PORT} localabstract:chrome_devtools_remote`, {
    encoding: 'utf8',
    timeout: 5000,
  });
}

/**
 * Attach a named screenshot to the Playwright test report.
 */
async function screenshot(page, testInfo, name) {
  const buf = await page.screenshot({ fullPage: false });
  await testInfo.attach(name, { body: buf, contentType: 'image/png' });
}

const test = base.extend({
  /**
   * cdpBrowser — worker-scoped fixture
   *
   * Single CDP connection held for the entire test file. Avoids the
   * connect/disconnect churn that destabilises the DevTools socket.
   */
  // eslint-disable-next-line no-empty-pattern
  cdpBrowser: [async ({}, use) => {
    ensureAdbForward();
    const browser = await chromium.connectOverCDP(`http://127.0.0.1:${CDP_PORT}`, {
      timeout: 10_000,
    });
    await use(browser);
    browser.close();
  }, { scope: 'worker' }],

  /**
   * emulatorPage — test-scoped fixture
   *
   * A fresh Chrome tab for each test. Clears localStorage on setup so
   * tests don't leak state through the shared default context.
   */
  emulatorPage: async ({ cdpBrowser }, use) => {
    // Android Chrome only supports a single default context — no newContext()
    const context = cdpBrowser.contexts()[0];
    const page = await context.newPage();

    // Clear localStorage before each test — shared context means all tabs
    // see the same origin storage, so previous test state leaks otherwise
    await page.goto(BASE_URL, { waitUntil: 'domcontentloaded' });
    await page.evaluate(() => localStorage.clear());

    await use(page);

    // Close the tab, leave the browser connection open for the next test
    await page.close().catch(() => {});
  },
});

module.exports = { test, expect, screenshot, CDP_PORT, BASE_URL };
