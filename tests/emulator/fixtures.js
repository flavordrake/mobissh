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
 * ADB helpers — real Android input for reliable gesture testing.
 * These go through the kernel/compositor/DOM pipeline, unlike CDP touches.
 */
function adbSwipe(x1, y1, x2, y2, durationMs = 300) {
  execSync(`adb shell input swipe ${x1} ${y1} ${x2} ${y2} ${durationMs}`);
}

function adbTap(x, y) {
  execSync(`adb shell input tap ${x} ${y}`);
}

/**
 * Prime the emulator's ADB touch pipeline with throwaway swipes.
 * Chrome Android has a "cold start" where the first ADB swipes after
 * page load may not reliably deliver touch events to JavaScript.
 * Call this before any scroll assertions.
 *
 * @param {object} [bounds] - If provided, swipes within the visible terminal
 *   area (important when keyboard is visible). Falls back to mid-screen coords.
 */
function warmupTouch(bounds) {
  if (bounds) {
    const margin = Math.round((bounds.bottom - bounds.top) * 0.15);
    const y1 = bounds.top + margin;
    const y2 = bounds.bottom - margin;
    adbSwipe(bounds.centerX, y1, bounds.centerX, y2, 300);
    adbSwipe(bounds.centerX, y2, bounds.centerX, y1, 300);
  } else {
    adbSwipe(540, 800, 540, 1400, 300);
    adbSwipe(540, 1400, 540, 800, 300);
  }
}

function dismissKeyboard() {
  execSync('adb shell input keyevent KEYCODE_BACK');
}

/**
 * Reliably dismiss the on-screen keyboard AND ensure it's actually gone.
 *
 * CRITICAL: Only sends KEYCODE_BACK if the keyboard is actually visible.
 * If the keyboard is NOT visible, KEYCODE_BACK navigates Chrome back,
 * destroying the test page and all state.
 *
 * Steps:
 *   1. Blur any focused input (prevents keyboard from auto-reopening)
 *   2. Check if keyboard is visible via visualViewport
 *   3. Only send KEYCODE_BACK if keyboard is actually showing
 *   4. Wait for keyboard animation to complete
 *   5. Verify keyboard is gone
 */
async function ensureKeyboardDismissed(page) {
  // Blur first — prevents keyboard from reopening on next touch
  await page.evaluate(() => {
    const el = document.activeElement;
    if (el && el !== document.body) el.blur();
  });

  // Check if keyboard is actually visible before sending KEYCODE_BACK
  const isVisible = await page.evaluate(() => {
    const vv = window.visualViewport;
    return vv ? vv.height < window.innerHeight * 0.75 : false;
  });

  if (isVisible) {
    dismissKeyboard();
    await new Promise(r => setTimeout(r, 800));

    // Verify
    const stillVisible = await page.evaluate(() => {
      const vv = window.visualViewport;
      return vv ? vv.height < window.innerHeight * 0.75 : false;
    });

    if (stillVisible) {
      await page.evaluate(() => {
        const el = document.activeElement;
        if (el && el !== document.body) el.blur();
      });
      dismissKeyboard();
      await new Promise(r => setTimeout(r, 800));
    }
  } else {
    // Keyboard not visible — just wait a moment for blur to settle
    await new Promise(r => setTimeout(r, 200));
  }
}

/**
 * Measure the Y offset from the top of the screen to Chrome's content area.
 * ADB coordinates are screen-absolute; CSS coordinates are viewport-relative.
 * The offset accounts for the Android status bar + Chrome URL bar.
 *
 * Technique: send an ADB tap at a known screen position, capture the resulting
 * DOM touchstart event's clientY, then compute:
 *   offset = adbY - (clientY * devicePixelRatio)
 *
 * Uses ADB (not CDP) because CDP synthetic touches don't report correct
 * screenY values in Android Chrome, making screenY-based calibration unreliable.
 *
 * The probe listener calls stopImmediatePropagation + preventDefault to
 * prevent the tap from triggering app handlers (scroll, focus, etc.).
 *
 * Cached per page (the offset doesn't change during a test).
 */
async function measureScreenOffset(page) {
  if (page.__screenOffset !== undefined) return page.__screenOffset;

  // Capture-phase listener on document fires before all app handlers.
  // stopImmediatePropagation prevents any other handler from seeing this probe.
  await page.evaluate(() => {
    window.__offsetProbeResult = null;
    document.addEventListener('touchstart', (e) => {
      if (e.touches.length > 0) {
        window.__offsetProbeResult = { clientY: e.touches[0].clientY };
      }
      e.preventDefault();
      e.stopImmediatePropagation();
    }, { once: true, capture: true });
  });

  // ADB tap in the middle of the screen — guaranteed to be in Chrome's content area
  const adbProbeX = 540;
  const adbProbeY = 1200;
  adbTap(adbProbeX, adbProbeY);
  await new Promise(r => setTimeout(r, 300));

  const result = await page.evaluate(() => {
    const r = window.__offsetProbeResult;
    delete window.__offsetProbeResult;
    return r;
  });

  if (result && typeof result.clientY === 'number') {
    const dpr = await page.evaluate(() => window.devicePixelRatio || 1);
    // offset_device_px = adb_screen_y - css_client_y * dpr
    page.__screenOffset = Math.round(adbProbeY - result.clientY * dpr);
  } else {
    // Fallback: typical Pixel 7 Chrome UI offset (status bar + URL bar)
    page.__screenOffset = 280;
  }

  return page.__screenOffset;
}

/**
 * Get the visible terminal bounds in ADB screen pixels.
 * Accounts for keyboard visibility via visualViewport and the Chrome UI
 * offset (status bar + URL bar) so coordinates are screen-absolute for ADB.
 * Returns null if the terminal element isn't found.
 */
async function getVisibleTerminalBounds(page) {
  const screenOffset = await measureScreenOffset(page);

  return page.evaluate((offset) => {
    const el = document.querySelector('.xterm-screen') || document.querySelector('#terminal');
    if (!el) return null;
    const rect = el.getBoundingClientRect();
    const vv = window.visualViewport;
    const dpr = window.devicePixelRatio || 1;

    // Visible viewport bounds in CSS pixels (accounts for keyboard)
    const vpTop = vv ? vv.offsetTop : 0;
    const vpBottom = vv ? vv.offsetTop + vv.height : window.innerHeight;

    // Intersection: visible portion of terminal
    const visTop = Math.max(rect.top, vpTop);
    const visBottom = Math.min(rect.bottom, vpBottom);

    // Convert to screen pixels for ADB, adding Chrome UI offset
    const bounds = {
      top: Math.round(visTop * dpr) + offset,
      bottom: Math.round(visBottom * dpr) + offset,
      left: Math.round(rect.left * dpr),
      right: Math.round(rect.right * dpr),
      centerX: Math.round((rect.left + rect.right) / 2 * dpr),
      keyboardVisible: vv ? vv.height < window.innerHeight * 0.75 : false,
    };

    // Sanity check: ADB coordinates must be non-negative and within screen
    if (bounds.top < 0 || bounds.bottom <= bounds.top) {
      console.warn('[bounds] Invalid ADB bounds detected:', JSON.stringify(bounds),
        'offset=', offset, 'rect.top=', rect.top, 'visTop=', visTop, 'dpr=', dpr);
    }

    return bounds;
  }, screenOffset);
}

/**
 * Intent-based swipe helpers.
 * Tests express WHAT they want ("scroll to older content") and the helper
 * computes the physical ADB swipe direction based on the current
 * naturalVerticalScroll / naturalHorizontalScroll setting.
 *
 * Emulates human thumb positioning:
 * - X: right 1/4 of the screen (natural right-hand thumb rest), NOT center
 * - Y: starts just above keyboard or ~2/3 down the screen
 * - Slight horizontal drift (5%) for natural diagonal motion
 * - Uses ADB (full Android input pipeline), NEVER CDP for scroll assertions
 *
 * @param {import('@playwright/test').Page} page
 * @param {{ top: number, bottom: number, left: number, right: number, centerX: number }} bounds
 *   Screen-absolute ADB coordinates from getVisibleTerminalBounds()
 * @param {number} [marginPct=0.15] Inset from edges (fraction of height/width)
 * @param {number} [duration=600] Swipe duration in ms
 */
async function swipeToOlderContent(page, bounds, marginPct = 0.15, duration = 1000) {
  const natural = await page.evaluate(() =>
    localStorage.getItem('naturalVerticalScroll') !== 'false');
  const margin = (bounds.bottom - bounds.top) * marginPct;
  // Human thumb: right 3/4 of the terminal width (right-hand thumb rest)
  const thumbX = Math.round(bounds.left + (bounds.right - bounds.left) * 0.75);
  // Slight horizontal drift for natural diagonal motion
  const drift = Math.round((bounds.right - bounds.left) * 0.05);
  // Natural: finger DOWN (top→bottom) = see older content
  // Traditional: finger UP (bottom→top) = see older content
  const [y1, y2] = natural
    ? [bounds.top + margin, bounds.bottom - margin]
    : [bounds.bottom - margin, bounds.top + margin];
  adbSwipe(thumbX, Math.round(y1), thumbX - drift, Math.round(y2), duration);
}

async function swipeToNewerContent(page, bounds, marginPct = 0.15, duration = 1000) {
  const natural = await page.evaluate(() =>
    localStorage.getItem('naturalVerticalScroll') !== 'false');
  const margin = (bounds.bottom - bounds.top) * marginPct;
  const thumbX = Math.round(bounds.left + (bounds.right - bounds.left) * 0.75);
  const drift = Math.round((bounds.right - bounds.left) * 0.05);
  // Natural: finger UP (bottom→top) = see newer content
  // Traditional: finger DOWN (top→bottom) = see newer content
  const [y1, y2] = natural
    ? [bounds.bottom - margin, bounds.top + margin]
    : [bounds.top + margin, bounds.bottom - margin];
  adbSwipe(thumbX, Math.round(y1), thumbX + drift, Math.round(y2), duration);
}

/**
 * Expected SGR mouse wheel button for "scroll to older content".
 * Natural scroll: finger down sends WheelUp (64).
 * Traditional scroll: finger up sends WheelUp (64).
 * Either way, scrolling to older always produces button 64.
 */
function expectedSGRButton(/* intent = 'older' */) {
  // WheelUp (64) = scroll to older content, regardless of natural/traditional setting.
  // The direction setting only changes which physical swipe direction maps to which intent.
  // The SGR button code for "scroll to older" is always 64.
  return { older: 64, newer: 65 };
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

    // Vault setup modal should appear on first launch (no vault in clean localStorage).
    // Fill the form and click Create. Fail loudly if this doesn't work — a stuck
    // overlay blocks every subsequent test.
    const modalAppeared = await page.locator('#vaultSetupOverlay:not(.hidden)')
      .waitFor({ state: 'visible', timeout: 10_000 })
      .then(() => true)
      .catch(() => false);

    if (!modalAppeared) {
      // Vault might exist from a prior tab's write in the shared context — verify
      const hasVault = await page.evaluate(() => !!localStorage.getItem('vaultMeta'));
      if (!hasVault) {
        throw new Error('emulatorPage fixture: vault setup modal did not appear and no vault in localStorage');
      }
    } else {
      await page.locator('#vaultNewPw').fill('test');
      await page.locator('#vaultConfirmPw').fill('test');
      await page.evaluate(() => {
        const cb = document.getElementById('vaultEnableBio');
        if (cb) cb.checked = false;
      });
      // Dismiss keyboard so it doesn't cover the Create button
      dismissKeyboard();
      await page.waitForTimeout(300);
      await page.evaluate(() => {
        document.getElementById('vaultSetupCreate')?.click();
      });
      await page.locator('#vaultSetupOverlay').waitFor({ state: 'hidden', timeout: 5000 });
    }

    // Ensure terminal panel is active — vault creation or app init may show Connect
    await page.locator('[data-panel="terminal"]').click();

    await use(page);

    // Close the tab, leave the browser connection open for the next test
    await page.close().catch(() => {});
  },

  /**
   * cleanPage — test-scoped fixture
   *
   * Like emulatorPage but does NOT create a vault. Use this for tests that
   * need to exercise the vault setup flow from scratch (vault-regression,
   * vault smoke tests). After setup: page is at BASE_URL with empty
   * localStorage and any vault overlay left as-is.
   */
  cleanPage: async ({ cdpBrowser }, use) => {
    const context = cdpBrowser.contexts()[0];
    const page = await context.newPage();

    try {
      const nagBtn = page.locator('button:has-text("No thanks"), button:has-text("No, thanks"), button:has-text("Not now"), button:has-text("Skip"), [id*="negative"], [id*="dismiss"]');
      await nagBtn.first().click({ timeout: 2000 });
    } catch { /* no nag modal */ }

    await page.goto(BASE_URL, { waitUntil: 'domcontentloaded' });
    await page.evaluate(() => localStorage.clear());
    await page.reload({ waitUntil: 'domcontentloaded' });

    await use(page);
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

// ── Intent-based testing infrastructure ─────────────────────────────────────

/**
 * IntentCapture — abstract user intent input.
 *
 * Records what the user *intended* to type, independent of how Gboard delivers
 * it. swipeType() fires a synthetic IME composition sequence (compositionstart,
 * compositionupdate word-by-word, compositionend + beforeinput/input) that
 * mirrors the pattern used in tests/ime.spec.js.
 */
class IntentCapture {
  constructor(page) {
    this.page = page;
    /** The full sentence the user intended. */
    this.intended = '';
  }

  /**
   * Simulate Gboard swipe input for a full sentence.
   * Fires composition events word-by-word as Gboard delivers swipe completions.
   * Accumulates into this.intended.
   */
  async swipeType(sentence) {
    this.intended += (this.intended ? ' ' : '') + sentence;
    const words = sentence.split(/\s+/).filter(Boolean);

    for (let w = 0; w < words.length; w++) {
      const word = words[w];
      await this.page.evaluate((t) => {
        const el = document.getElementById('imeInput');
        if (!el) return;
        el.focus();
        // compositionstart
        el.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
        // compositionupdate: character by character
        for (let i = 1; i <= t.length; i++) {
          const partial = t.slice(0, i);
          el.dispatchEvent(new CompositionEvent('compositionupdate', {
            bubbles: true, data: partial,
          }));
        }
        // Update textarea value (Gboard sets it on compositionend)
        el.value = (el.value ? el.value + ' ' : '') + t;
        // compositionend
        el.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: t }));
        // beforeinput + input (browser fires these after compositionend)
        el.dispatchEvent(new InputEvent('beforeinput', {
          bubbles: true, inputType: 'insertCompositionText', data: t,
        }));
        el.dispatchEvent(new InputEvent('input', {
          bubbles: true, inputType: 'insertCompositionText', data: t,
        }));
      }, word);
      // Small delay between words, as Gboard delivers them
      await new Promise(r => setTimeout(r, 50));
    }
  }
}

/**
 * TerminalReceiver — monitor what the terminal actually received.
 *
 * Wraps the WS spy to track cumulative terminal state. getReceivedText()
 * collapses backspace/delete sequences so corrections don't skew comparison.
 */
class TerminalReceiver {
  constructor(page) {
    this.page = page;
  }

  /**
   * Return the net text the terminal received after applying backspaces.
   * Each \x7f deletes one character from the accumulated result.
   */
  async getReceivedText() {
    return this.page.evaluate(() => {
      const spy = window.__mockWsSpy || [];
      const inputMsgs = spy
        .map(s => { try { return JSON.parse(s); } catch { return null; } })
        .filter(m => m && m.type === 'input')
        .map(m => m.data);

      // Collapse: apply backspaces to produce net result
      let result = '';
      for (const chunk of inputMsgs) {
        for (const ch of chunk) {
          if (ch === '\x7f') {
            result = result.slice(0, -1);
          } else {
            result += ch;
          }
        }
      }
      return result;
    });
  }

  /** Reset the spy so subsequent assertions are clean. */
  async reset() {
    await this.page.evaluate(() => { window.__mockWsSpy = []; });
  }
}

/**
 * assertFaithful — the North Star assertion.
 *
 * Asserts that terminal received === user intended. On failure, reports a diff
 * showing exactly where intent diverges from terminal output.
 */
async function assertFaithful(intent, receiver, expect) {
  const received = await receiver.getReceivedText();
  const intended = intent.intended;

  // Strip trailing \r from received for comparison (Enter adds \r after text)
  const receivedText = received.endsWith('\r') ? received.slice(0, -1) : received;

  if (receivedText !== intended) {
    const diff = [];
    const maxLen = Math.max(intended.length, receivedText.length);
    let firstDiff = -1;
    for (let i = 0; i < maxLen; i++) {
      if (intended[i] !== receivedText[i]) { firstDiff = i; break; }
    }
    diff.push(`[assertFaithful] intent != terminal`);
    diff.push(`  intended  (${intended.length}): ${intended.slice(0, 80)}...`);
    diff.push(`  received  (${receivedText.length}): ${receivedText.slice(0, 80)}...`);
    if (firstDiff >= 0) {
      diff.push(`  first diff at position ${firstDiff}`);
      diff.push(`  intended[${firstDiff}]:  ${JSON.stringify(intended.slice(Math.max(0,firstDiff-5), firstDiff+10))}`);
      diff.push(`  received[${firstDiff}]:  ${JSON.stringify(receivedText.slice(Math.max(0,firstDiff-5), firstDiff+10))}`);
    }
    expect(receivedText, diff.join('\n')).toBe(intended);
  }
}

// ── State machine introspection helpers ──────────────────────────────────────

/** Get current IME state machine state and relevant UI state. */
async function getIMEState(page) {
  return page.evaluate(() => {
    // Access via module export (app already loaded it)
    const state = typeof window.__imeStateForTests === 'function'
      ? window.__imeStateForTests()
      : null;
    const imeInput = document.getElementById('imeInput');
    const previewBtn = document.getElementById('previewModeBtn');
    return {
      state,
      previewMode: previewBtn ? previewBtn.classList.contains('preview-active') : false,
      text: imeInput ? imeInput.value : '',
    };
  });
}

/** Enable preview mode (click the eye button if not already active). */
async function enablePreviewMode(page) {
  await page.evaluate(() => {
    const btn = document.getElementById('previewModeBtn');
    if (btn && !btn.classList.contains('preview-active')) btn.click();
  });
  await new Promise(r => setTimeout(r, 100));
}

/** Disable preview mode (click the eye button if currently active). */
async function disablePreviewMode(page) {
  await page.evaluate(() => {
    const btn = document.getElementById('previewModeBtn');
    if (btn && btn.classList.contains('preview-active')) btn.click();
  });
  await new Promise(r => setTimeout(r, 100));
}

/** Enable compose mode (click compose button if not already active). */
async function enableComposeMode(page) {
  await page.evaluate(() => {
    const btn = document.getElementById('composeModeBtn');
    if (btn && !btn.classList.contains('compose-active')) btn.click();
  });
  await new Promise(r => setTimeout(r, 100));
}

/** Tap the Commit (send) button. */
async function tapCommit(page) {
  await page.evaluate(() => {
    const btn = document.getElementById('imeCommitBtn');
    if (btn) btn.click();
  });
  await new Promise(r => setTimeout(r, 100));
}

/** Tap the Clear button. */
async function tapClear(page) {
  await page.evaluate(() => {
    const btn = document.getElementById('imeClearBtn');
    if (btn) btn.click();
  });
  await new Promise(r => setTimeout(r, 100));
}

module.exports = {
  test, expect, screenshot, setupRealSSHConnection, sendCommand,
  swipe, pinch, adbSwipe, adbTap, dismissKeyboard, ensureKeyboardDismissed,
  warmupTouch, getVisibleTerminalBounds,
  swipeToOlderContent, swipeToNewerContent, expectedSGRButton,
  CDP_PORT, BASE_URL,
  COMPOSE_INPUT_ID, DIRECT_INPUT_ID, DIRECT_INPUT_TYPE,
  // Intent-based testing infrastructure
  IntentCapture, TerminalReceiver, assertFaithful,
  getIMEState, enablePreviewMode, disablePreviewMode, enableComposeMode,
  tapCommit, tapClear,
};
