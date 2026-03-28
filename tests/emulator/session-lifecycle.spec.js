/**
 * tests/emulator/session-lifecycle.spec.js
 *
 * Emulator-based integration tests for multi-session lifecycle.
 * These test REAL Android Chrome behavior that headless can't reproduce:
 * - Terminal resize after panel navigation
 * - Terminal resize after app backgrounding
 * - Multi-session switching
 * - Connection persistence
 *
 * Run: npx playwright test --config=playwright.emulator.config.js tests/emulator/session-lifecycle.spec.js
 */

const { test, expect, screenshot, dismissKeyboard, BASE_URL } = require('./fixtures');
const { SSHD_HOST, SSHD_PORT, TEST_USER, TEST_PASS } = require('./sshd-fixture');

const WS_HOST = process.env.WS_HOST || '10.0.2.2:8081';

/** Connect to test-sshd from the Connect panel. */
async function connectToTestSshd(page, testInfo, label = '') {
  // Navigate to Connect panel
  await page.goto(BASE_URL);
  await page.waitForSelector('#connectForm', { timeout: 30_000 });

  // Override WS URL to use QEMU host gateway
  await page.evaluate((wsHost) => {
    localStorage.setItem('wsUrl', `ws://${wsHost}`);
  }, WS_HOST);

  // Fill connection form
  await page.locator('#host').fill(SSHD_HOST);
  await page.locator('#remote_a').fill(TEST_USER);
  await page.locator('#remote_c').fill(TEST_PASS);
  await page.locator('#connectForm button[type="submit"]').click();
  await page.waitForTimeout(500);

  // Click Connect on the saved profile
  await page.locator('[data-action="connect"]').first().click();
  if (label) await screenshot(page, testInfo, `${label}-connecting`);

  // Wait for terminal to render
  await page.waitForSelector('.xterm-screen', { timeout: 30_000 });
  await page.waitForTimeout(1000);
  if (label) await screenshot(page, testInfo, `${label}-connected`);
}

/** Get terminal columns from the page. */
async function getTerminalCols(page) {
  return page.evaluate(() => {
    // @ts-ignore
    return window.__mobissh_state?.currentSession?.terminal?.cols ?? 0;
  });
}

/** Get terminal screen width in pixels. */
async function getTerminalWidth(page) {
  return page.evaluate(() => {
    const el = document.querySelector('.xterm-screen');
    return el ? el.clientWidth : 0;
  });
}

test.describe('Session lifecycle (Android emulator)', () => {

  test('terminal fills screen width after initial connect', async ({ emulatorPage: page }, testInfo) => {
    await connectToTestSshd(page, testInfo, '01');

    const width = await getTerminalWidth(page);
    await screenshot(page, testInfo, '01-terminal-width');

    // Terminal should fill most of the viewport (>80% of screen width)
    const viewportWidth = await page.evaluate(() => window.innerWidth);
    expect(width).toBeGreaterThan(viewportWidth * 0.8);
  });

  test('terminal retains correct width after navigating to Connect and back', async ({ emulatorPage: page }, testInfo) => {
    await connectToTestSshd(page, testInfo, '02');

    const widthBefore = await getTerminalWidth(page);
    await screenshot(page, testInfo, '02-before-navigate');

    // Navigate to Connect panel via hamburger menu
    await page.locator('#handleMenuBtn').click();
    await page.waitForTimeout(300);
    await page.locator('[data-panel="connect"]').click();
    await page.waitForTimeout(500);
    await screenshot(page, testInfo, '02-on-connect-panel');

    // Navigate back to terminal
    await page.locator('[data-panel="terminal"]').click();
    await page.waitForTimeout(2000); // Wait for fit + refresh
    await screenshot(page, testInfo, '02-back-to-terminal');

    const widthAfter = await getTerminalWidth(page);
    // Width should be within 10% of original — not shrunken
    expect(widthAfter).toBeGreaterThan(widthBefore * 0.8);
  });

  test('terminal retains correct width after app background and resume', async ({ emulatorPage: page }, testInfo) => {
    await connectToTestSshd(page, testInfo, '03');

    const widthBefore = await getTerminalWidth(page);
    await screenshot(page, testInfo, '03-before-background');

    // Background the app via ADB
    const { execSync } = require('child_process');
    execSync('adb shell input keyevent KEYCODE_HOME');
    await page.waitForTimeout(3000);

    // Resume the app
    execSync('adb shell am start -n com.android.chrome/com.google.android.apps.chrome.Main');
    await page.waitForTimeout(3000);
    await screenshot(page, testInfo, '03-after-resume');

    const widthAfter = await getTerminalWidth(page);
    expect(widthAfter).toBeGreaterThan(widthBefore * 0.8);
  });

  test('session menu opens on first tap', async ({ emulatorPage: page }, testInfo) => {
    await connectToTestSshd(page, testInfo, '04');

    // Tap session menu button
    await page.locator('#sessionMenuBtn').tap();
    await page.waitForTimeout(500);
    await screenshot(page, testInfo, '04-session-menu');

    const menuVisible = await page.locator('#sessionMenu').evaluate(el => !el.classList.contains('hidden'));
    expect(menuVisible).toBe(true);
  });
});
