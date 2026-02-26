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
const { ensureTestSshd, SSHD_HOST, SSHD_PORT, TEST_USER, TEST_PASS } = require('./sshd-fixture');

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
   * sshServer — worker-scoped fixture
   *
   * Ensures the Docker test-sshd container is running and returns
   * connection credentials for real SSH integration tests.
   */
  // eslint-disable-next-line no-empty-pattern
  sshServer: [async ({}, use) => {
    ensureTestSshd();
    await use({ host: SSHD_HOST, port: SSHD_PORT, user: TEST_USER, password: TEST_PASS });
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

    // Clear localStorage then reload — shared context means all tabs see the
    // same origin storage. The app reads localStorage on init (panel state,
    // vault, profiles), so we must clear BEFORE the app initializes.
    await page.goto(BASE_URL, { waitUntil: 'domcontentloaded' });
    await page.evaluate(() => localStorage.clear());
    await page.reload({ waitUntil: 'domcontentloaded' });

    await use(page);

    // Close the tab, leave the browser connection open for the next test
    await page.close().catch(() => {});
  },
});

/**
 * Connect to a real SSH server through the MobiSSH bridge.
 * Sets up vault, fills connect form, accepts host key, waits for shell.
 *
 * NOTE: The emulatorPage fixture already navigated to BASE_URL and cleared
 * localStorage. We do NOT navigate again — injecting state on the live page.
 */
async function setupRealSSHConnection(page, sshServer) {
  await page.waitForSelector('.xterm-screen', { timeout: 30_000 });

  // Enable private host connections (SSRF bypass for Docker sshd on localhost),
  // inject WS spy, and create a test vault — all on the already-loaded page.
  await page.evaluate(async () => {
    localStorage.setItem('allowPrivateHosts', 'true');

    // WS spy — must be injected AFTER navigation, on the live page
    window.__mockWsSpy = [];
    const OrigWS = window.WebSocket;
    window.WebSocket = class extends OrigWS {
      send(data) { window.__mockWsSpy.push(data); super.send(data); }
    };

    const { createVault } = await import('./modules/vault.js');
    await createVault('test', false);
  });

  // Navigate to connect form
  await page.locator('[data-panel="connect"]').click();
  await page.waitForSelector('#panel-connect.active', { timeout: 5000 });

  // Fill credentials
  await page.locator('#host').fill(sshServer.host);
  await page.locator('#port').fill(String(sshServer.port));
  await page.locator('#username').fill(sshServer.user);
  await page.locator('#password').fill(sshServer.password);

  // Submit — button has no id, select by form + type
  await page.locator('#connectForm button[type="submit"]').click();

  // Accept host key on first connection
  try {
    const acceptBtn = page.locator('.hostkey-accept');
    await acceptBtn.waitFor({ timeout: 10_000 });
    await acceptBtn.click();
  } catch {
    // Host key already trusted from a previous test in this worker
  }

  // Wait for connected state — resize message confirms shell is ready
  await page.waitForFunction(() => {
    return (window.__mockWsSpy || []).some(s => {
      try { return JSON.parse(s).type === 'resize'; } catch { return false; }
    });
  }, null, { timeout: 15_000 });

  // Ensure terminal panel is active
  await page.waitForSelector('#panel-terminal.active', { timeout: 5000 });
}

/**
 * Type a command into the terminal via the IME input and send Enter.
 */
async function sendCommand(page, cmd) {
  // Focus the IME input
  await page.evaluate(() => {
    const el = document.getElementById('imeInput') || document.getElementById('directInput');
    if (el) el.focus();
  });

  for (const ch of cmd) {
    await page.evaluate((c) => {
      const el = document.getElementById('imeInput') || document.getElementById('directInput');
      if (!el) return;
      el.value = c;
      el.dispatchEvent(new InputEvent('input', { bubbles: true, data: c }));
      el.value = '';
    }, ch);
  }
  // Enter
  await page.evaluate(() => {
    const el = document.getElementById('imeInput') || document.getElementById('directInput');
    if (!el) return;
    el.value = '\n';
    el.dispatchEvent(new InputEvent('input', { bubbles: true, data: '\n' }));
    el.value = '';
  });
}

/**
 * Dispatch a swipe gesture on an element via synthetic TouchEvents.
 * Coordinates are relative to the element.
 */
async function swipe(page, selector, startX, startY, endX, endY, steps = 10) {
  await page.evaluate(({ sel, sx, sy, ex, ey, steps }) => {
    const el = document.querySelector(sel);
    if (!el) throw new Error(`swipe: element ${sel} not found`);
    const rect = el.getBoundingClientRect();
    const ax = rect.left + sx;
    const ay = rect.top + sy;
    const bx = rect.left + ex;
    const by = rect.top + ey;

    function fire(type, x, y) {
      const t = new Touch({ identifier: 0, target: el, clientX: x, clientY: y, pageX: x, pageY: y });
      el.dispatchEvent(new TouchEvent(type, {
        bubbles: true, cancelable: true,
        touches: type === 'touchend' ? [] : [t],
        changedTouches: [t],
        targetTouches: type === 'touchend' ? [] : [t],
      }));
    }

    fire('touchstart', ax, ay);
    for (let i = 1; i <= steps; i++) {
      const f = i / steps;
      fire('touchmove', ax + (bx - ax) * f, ay + (by - ay) * f);
    }
    fire('touchend', bx, by);
  }, { sel: selector, sx: startX, sy: startY, ex: endX, ey: endY, steps });
}

/**
 * Dispatch a 2-finger pinch gesture on an element.
 * startDist/endDist are the pixel distance between the two fingers.
 * endDist > startDist = zoom in, endDist < startDist = zoom out.
 */
async function pinch(page, selector, startDist, endDist, steps = 10) {
  await page.evaluate(({ sel, sd, ed, steps }) => {
    const el = document.querySelector(sel);
    if (!el) throw new Error(`pinch: element ${sel} not found`);
    const rect = el.getBoundingClientRect();
    const cx = rect.left + rect.width / 2;
    const cy = rect.top + rect.height / 2;

    function fire(type, dist) {
      const t0 = new Touch({ identifier: 0, target: el, clientX: cx - dist / 2, clientY: cy, pageX: cx - dist / 2, pageY: cy });
      const t1 = new Touch({ identifier: 1, target: el, clientX: cx + dist / 2, clientY: cy, pageX: cx + dist / 2, pageY: cy });
      const tl = type === 'touchend' ? [] : [t0, t1];
      el.dispatchEvent(new TouchEvent(type, {
        bubbles: true, cancelable: true,
        touches: tl, changedTouches: [t0, t1], targetTouches: tl,
      }));
    }

    fire('touchstart', sd);
    for (let i = 1; i <= steps; i++) {
      fire('touchmove', sd + (ed - sd) * (i / steps));
    }
    fire('touchend', ed);
  }, { sel: selector, sd: startDist, ed: endDist, steps });
}

module.exports = {
  test, expect, screenshot, setupRealSSHConnection, sendCommand,
  swipe, pinch, CDP_PORT, BASE_URL,
};
