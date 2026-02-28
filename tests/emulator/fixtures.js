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

// ── Input element helpers ────────────────────────────────────────────────────
// Centralises element IDs and expected properties so tests don't hardcode them.

/** ID of the compose-mode textarea (IME/swipe input). */
const COMPOSE_INPUT_ID = 'imeInput';
/** ID of the direct-mode hidden input (char-by-char, no IME). */
const DIRECT_INPUT_ID  = 'directInput';
/** Expected `type` attribute of the direct-mode input. */
const DIRECT_INPUT_TYPE = 'password';

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

    // Dismiss any Chrome nag modals (notification prompt, sign-in, etc.) that
    // may appear on first launch (#141). These are native Chrome UI, not web
    // content — look for common dismiss buttons.
    try {
      const nagBtn = page.locator('button:has-text("No thanks"), button:has-text("No, thanks"), button:has-text("Not now"), button:has-text("Skip"), [id*="negative"], [id*="dismiss"]');
      await nagBtn.first().click({ timeout: 2000 });
    } catch { /* no nag modal present — normal case after first run */ }

    // Clear localStorage then reload — shared context means all tabs see the
    // same origin storage. The app reads localStorage on init (panel state,
    // vault, profiles), so we must clear BEFORE the app initializes.
    await page.goto(BASE_URL, { waitUntil: 'domcontentloaded' });
    await page.evaluate(() => localStorage.clear());
    await page.reload({ waitUntil: 'domcontentloaded' });

    // Vault setup modal appears on first launch (no vault in clean localStorage).
    // Fill the form and click Create like a real user.
    try {
      await page.waitForSelector('#vaultSetupOverlay:not(.hidden)', { timeout: 10_000 });
      await page.locator('#vaultNewPw').fill('test');
      await page.locator('#vaultConfirmPw').fill('test');
      // Disable biometric — WebAuthn enrollment hangs without enrolled fingerprint
      await page.evaluate(() => {
        const cb = document.getElementById('vaultEnableBio');
        if (cb) cb.checked = false;
      });
      // Dismiss keyboard so it doesn't cover the Create button
      await page.evaluate(() => document.activeElement?.blur());
      await page.waitForTimeout(500);
      // Use DOM click — Playwright click can be intercepted by overlay
      await page.evaluate(() => {
        const btn = document.getElementById('vaultSetupCreate');
        if (btn) btn.click();
      });
      await page.waitForSelector('#vaultSetupOverlay.hidden', { timeout: 5000 });
    } catch { /* vault already exists or modal didn't appear */ }

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

  // Enable private host connections (SSRF bypass for Docker sshd on localhost)
  // and inject WS spy. Vault is already created by the emulatorPage fixture.
  await page.evaluate(() => {
    localStorage.setItem('allowPrivateHosts', 'true');

    // WS spy — must be injected AFTER navigation, on the live page
    window.__mockWsSpy = [];
    const OrigWS = window.WebSocket;
    window.WebSocket = class extends OrigWS {
      send(data) { window.__mockWsSpy.push(data); super.send(data); }
    };
  });

  // Navigate to connect form
  await page.locator('[data-panel="connect"]').click();
  await page.waitForSelector('#panel-connect.active', { timeout: 5000 });

  // Fill credentials
  await page.locator('#host').fill(sshServer.host);
  await page.locator('#port').fill(String(sshServer.port));
  await page.locator('#remote_a').fill(sshServer.user);
  await page.locator('#remote_c').fill(sshServer.password);

  // Submit — button has no id, select by form + type
  await page.locator('#connectForm button[type="submit"]').click();

  // Accept host key on first connection — each test clears localStorage so
  // the stored fingerprint is always gone. Wait for the dialog to appear,
  // then dismiss keyboard (password field may have focused it) and click.
  try {
    const acceptBtn = page.locator('.hostkey-accept');
    await acceptBtn.waitFor({ state: 'visible', timeout: 15_000 });
    // Dismiss keyboard — filling the password field may have opened it,
    // and the keyboard can interfere with click routing on Android.
    await page.evaluate(() => document.activeElement?.blur());
    await page.waitForTimeout(500);
    // Use DOM click via evaluate — Playwright's click() reports the
    // hostkey-overlay as intercepting even though the button is inside it.
    await page.evaluate(() => {
      const btn = document.querySelector('.hostkey-accept');
      if (btn) btn.click();
    });
    // Wait for the overlay to dismiss and connection to proceed
    await page.waitForTimeout(1000);
  } catch {
    // Host key already trusted (shouldn't happen with fresh localStorage)
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
  const ids = [COMPOSE_INPUT_ID, DIRECT_INPUT_ID];
  // Focus whichever input element exists
  await page.evaluate((ids) => {
    for (const id of ids) { const el = document.getElementById(id); if (el) { el.focus(); return; } }
  }, ids);

  for (const ch of cmd) {
    await page.evaluate(([c, ids]) => {
      for (const id of ids) { const el = document.getElementById(id); if (el) { el.value = c; el.dispatchEvent(new InputEvent('input', { bubbles: true, data: c })); el.value = ''; return; } }
    }, [ch, ids]);
  }
  // Enter
  await page.evaluate((ids) => {
    for (const id of ids) { const el = document.getElementById(id); if (el) { el.value = '\n'; el.dispatchEvent(new InputEvent('input', { bubbles: true, data: '\n' })); el.value = ''; return; } }
  }, ids);
}

/**
 * Get a CDP session for the page. Caches on the page object to avoid
 * creating multiple sessions per test.
 */
async function getCDPSession(page) {
  if (!page.__cdpSession) {
    page.__cdpSession = await page.context().newCDPSession(page);
  }
  return page.__cdpSession;
}

/**
 * Inject a touch visualizer into the page that draws finger positions
 * as colored circles. Renders in the DOM so screenrecord captures it.
 * CDP touches bypass Android's pointer_location overlay, so we draw our own.
 */
async function ensureTouchViz(page) {
  await page.evaluate(() => {
    if (document.getElementById('__touchViz')) return;
    const style = document.createElement('style');
    style.id = '__touchViz';
    style.textContent = `
      .__touch-dot {
        position: fixed; z-index: 99999; pointer-events: none;
        width: 28px; height: 28px; border-radius: 50%;
        background: rgba(0, 255, 136, 0.5); border: 2px solid #00ff88;
        transform: translate(-50%, -50%); transition: opacity 0.3s;
      }
      .__touch-trail {
        position: fixed; z-index: 99998; pointer-events: none;
        width: 8px; height: 8px; border-radius: 50%;
        background: rgba(0, 255, 136, 0.3);
        transform: translate(-50%, -50%);
      }
    `;
    document.head.appendChild(style);
  });
}

/**
 * Show touch dots at given positions, leave a trail, then fade.
 */
async function showTouchPoints(page, points) {
  await page.evaluate((pts) => {
    // Remove old dots
    document.querySelectorAll('.__touch-dot').forEach(el => el.remove());
    // Create new dots
    pts.forEach(({ x, y }) => {
      const dot = document.createElement('div');
      dot.className = '__touch-dot';
      dot.style.left = x + 'px';
      dot.style.top = y + 'px';
      document.body.appendChild(dot);
      // Trail dot (persists longer)
      const trail = document.createElement('div');
      trail.className = '__touch-trail';
      trail.style.left = x + 'px';
      trail.style.top = y + 'px';
      document.body.appendChild(trail);
      setTimeout(() => trail.remove(), 2000);
    });
  }, points);
}

async function clearTouchDots(page) {
  await page.evaluate(() => {
    document.querySelectorAll('.__touch-dot').forEach(el => el.remove());
  });
}

/**
 * Dispatch a swipe gesture on an element via CDP Input.dispatchTouchEvent.
 * Goes through Chrome's real input pipeline and fires DOM touch events.
 * Touch positions are visualized in the page for screen recording.
 * Coordinates are relative to the element (CSS pixels).
 */
async function swipe(page, selector, startX, startY, endX, endY, steps = 10) {
  const box = await page.locator(selector).boundingBox();
  if (!box) throw new Error(`swipe: element ${selector} not found`);

  const ax = box.x + startX;
  const ay = box.y + startY;
  const bx = box.x + endX;
  const by = box.y + endY;

  await ensureTouchViz(page);
  const client = await getCDPSession(page);

  await showTouchPoints(page, [{ x: ax, y: ay }]);
  await client.send('Input.dispatchTouchEvent', {
    type: 'touchStart',
    touchPoints: [{ x: ax, y: ay, id: 0 }],
  });

  for (let i = 1; i <= steps; i++) {
    const f = i / steps;
    const x = ax + (bx - ax) * f;
    const y = ay + (by - ay) * f;
    await showTouchPoints(page, [{ x, y }]);
    await client.send('Input.dispatchTouchEvent', {
      type: 'touchMove',
      touchPoints: [{ x, y, id: 0 }],
    });
    await new Promise(r => setTimeout(r, 30));
  }

  await client.send('Input.dispatchTouchEvent', {
    type: 'touchEnd',
    touchPoints: [],
  });
  await clearTouchDots(page);
}

/**
 * Dispatch a 2-finger pinch gesture on an element via CDP Input.dispatchTouchEvent.
 * Goes through Chrome's real input pipeline. Touch positions visualized for recording.
 * startDist/endDist are the pixel distance between the two fingers (CSS pixels).
 * endDist > startDist = zoom in, endDist < startDist = zoom out.
 */
async function pinch(page, selector, startDist, endDist, steps = 10) {
  const box = await page.locator(selector).boundingBox();
  if (!box) throw new Error(`pinch: element ${selector} not found`);

  const cx = box.x + box.width / 2;
  const cy = box.y + box.height / 2;

  await ensureTouchViz(page);
  const client = await getCDPSession(page);

  function points(dist) {
    return [
      { x: cx - dist / 2, y: cy, id: 0 },
      { x: cx + dist / 2, y: cy, id: 1 },
    ];
  }

  const startPts = points(startDist);
  await showTouchPoints(page, startPts);
  await client.send('Input.dispatchTouchEvent', {
    type: 'touchStart',
    touchPoints: startPts,
  });

  for (let i = 1; i <= steps; i++) {
    const dist = startDist + (endDist - startDist) * (i / steps);
    const pts = points(dist);
    await showTouchPoints(page, pts);
    await client.send('Input.dispatchTouchEvent', {
      type: 'touchMove',
      touchPoints: points(dist),
    });
    await new Promise(r => setTimeout(r, 30));
  }

  await client.send('Input.dispatchTouchEvent', {
    type: 'touchEnd',
    touchPoints: [],
  });
  await clearTouchDots(page);
}

module.exports = {
  test, expect, screenshot, setupRealSSHConnection, sendCommand,
  swipe, pinch, CDP_PORT, BASE_URL,
  COMPOSE_INPUT_ID, DIRECT_INPUT_ID, DIRECT_INPUT_TYPE,
};
