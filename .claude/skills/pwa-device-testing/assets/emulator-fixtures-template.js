/**
 * tests/emulator/fixtures.js — Template
 *
 * Playwright fixtures for Android emulator testing over CDP.
 * Provides a worker-scoped CDP connection and per-test tab isolation.
 *
 * Key constraints this template handles:
 *   - Android Chrome has ONE default context (no newContext())
 *   - localStorage is shared across all tabs in that context
 *   - CDP connection must be worker-scoped to avoid reconnect churn
 *   - Play Store Chrome requires set-debug-app for DevTools socket
 *
 * Adapt BASE_URL and CDP_PORT for your project.
 */

const { test: base, expect } = require('@playwright/test');
const { chromium } = require('@playwright/test');
const { execSync } = require('child_process');

const CDP_PORT = Number(process.env.CDP_PORT || 9222);
const BASE_URL = process.env.BASE_URL || 'http://localhost:8081';

/**
 * Ensure ADB is forwarding the Chrome DevTools port.
 */
function ensureAdbForward() {
  try {
    const existing = execSync('adb forward --list', { encoding: 'utf8' });
    if (existing.includes(`tcp:${CDP_PORT}`)) return;
  } catch { /* not forwarded yet */ }

  execSync(`adb forward tcp:${CDP_PORT} localabstract:chrome_devtools_remote`, {
    encoding: 'utf8',
    timeout: 5000,
  });
}

/**
 * Attach a named screenshot to the Playwright HTML test report.
 * Call at every decision point so the report tells the full story.
 */
async function screenshot(page, testInfo, name) {
  const buf = await page.screenshot({ fullPage: false });
  await testInfo.attach(name, { body: buf, contentType: 'image/png' });
}

const test = base.extend({
  /**
   * cdpBrowser — worker-scoped (one CDP connection per test file)
   *
   * MUST be worker-scoped. Per-test connect/disconnect destabilises the
   * DevTools socket after ~4-5 cycles and causes "Target closed" errors.
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
   * emulatorPage — test-scoped (fresh tab per test)
   *
   * Uses the single default context (Android Chrome limitation).
   * Clears localStorage before yielding so tests don't leak state.
   */
  emulatorPage: async ({ cdpBrowser }, use) => {
    const context = cdpBrowser.contexts()[0];
    const page = await context.newPage();

    // Clear localStorage — all tabs share it via the single context
    await page.goto(BASE_URL, { waitUntil: 'domcontentloaded' });
    await page.evaluate(() => localStorage.clear());

    await use(page);
    await page.close().catch(() => {});
  },
});

module.exports = { test, expect, screenshot, CDP_PORT, BASE_URL };
