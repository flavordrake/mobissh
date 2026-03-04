/**
 * tests/appium/fixtures.js
 *
 * Playwright test fixtures for Appium-based Android emulator testing.
 *
 * Uses WebDriverIO client to connect to Appium server, which controls
 * Chrome on the emulator via UiAutomator2 + Chromedriver.
 *
 * Provides: driver session management, context switching, gesture helpers,
 * SSH connection, terminal measurement, vault setup, screenshot attachment.
 *
 * Usage:
 *   const { test, expect } = require('./fixtures');
 *   test('my test', async ({ driver }) => { ... });
 */

const { test: base, expect } = require('@playwright/test');
const { remote } = require('webdriverio');
const { execSync } = require('child_process');
const path = require('path');
const { ensureTestSshd, SSHD_HOST, SSHD_PORT, TEST_USER, TEST_PASS } = require('../emulator/sshd-fixture');

/** Directory for per-test recordings. Set by run-appium-tests.sh via env var. */
const RECORDING_DIR = process.env.APPIUM_RECORDING_DIR || '';

const APPIUM_HOST = process.env.APPIUM_HOST || 'localhost';
const APPIUM_PORT = Number(process.env.APPIUM_PORT || 4723);
const BASE_URL = (process.env.BASE_URL || 'http://localhost:8081').replace(/\/?$/, '/');

/** ID of the compose-mode textarea (IME/swipe input). */
const COMPOSE_INPUT_ID = 'imeInput';
/** ID of the direct-mode hidden input (char-by-char, no IME). */
const DIRECT_INPUT_ID = 'directInput';

// ── Session management ──────────────────────────────────────────────────

/**
 * Fast check: is Appium server reachable? Fails in <3s instead of hanging
 * for 60s+ on connectionRetryTimeout.
 */
async function checkAppiumReachable() {
  const http = require('http');
  return new Promise((resolve, reject) => {
    const req = http.get(
      `http://${APPIUM_HOST}:${APPIUM_PORT}/status`,
      { timeout: 3000 },
      (res) => {
        res.resume(); // drain
        resolve(res.statusCode === 200);
      },
    );
    req.on('error', () => reject(new Error(
      `Appium server not reachable at ${APPIUM_HOST}:${APPIUM_PORT}. ` +
      'Start it with: ./scripts/start-appium.sh'
    )));
    req.on('timeout', () => {
      req.destroy();
      reject(new Error(
        `Appium server timeout at ${APPIUM_HOST}:${APPIUM_PORT}. ` +
        'Start it with: ./scripts/start-appium.sh'
      ));
    });
  });
}

/**
 * Create a WebDriverIO session connected to Appium.
 * Opens Chrome on the running emulator.
 * Fails fast (<3s) if Appium is not reachable.
 */
async function createDriver() {
  await checkAppiumReachable();
  const driver = await remote({
    hostname: APPIUM_HOST,
    port: APPIUM_PORT,
    capabilities: {
      platformName: 'Android',
      'appium:automationName': 'UiAutomator2',
      browserName: 'Chrome',
      'appium:noReset': true,
      'wdio:enforceWebDriverClassic': true,
      'goog:chromeOptions': {
        args: [
          '--disable-save-password-bubble',
          '--disable-password-generation',
          '--no-first-run',
          '--disable-translate',
        ],
      },
    },
    connectionRetryTimeout: 15000,
    connectionRetryCount: 1,
  });
  return driver;
}

// ── Context switching ───────────────────────────────────────────────────

/**
 * Switch to WEBVIEW context. Returns the context name.
 */
async function switchToWebview(driver) {
  const contexts = await driver.getContexts();
  const webview = contexts.find(c => c.startsWith('WEBVIEW') || c.startsWith('CHROMIUM'));
  if (!webview) {
    throw new Error(`No webview context found. Available: ${JSON.stringify(contexts)}`);
  }
  await driver.switchContext(webview);
  return webview;
}

/**
 * Switch to NATIVE_APP context for native UI interaction.
 */
async function switchToNative(driver) {
  await driver.switchContext('NATIVE_APP');
}

/**
 * Dismiss any native Chrome dialogs (password manager, translate, etc.)
 */
async function dismissNativeDialogs(driver) {
  try {
    await switchToNative(driver);
    for (const text of ['No thanks', 'Not now', 'OK', 'No, thanks', 'Never']) {
      const btns = await driver.$$(`android=new UiSelector().text("${text}")`);
      if (btns.length > 0 && await btns[0].isDisplayed()) {
        await btns[0].click();
        await driver.pause(500);
      }
    }
  } catch {
    // Context switch failed or no dialogs
  }
}

// ── Keyboard management ─────────────────────────────────────────────────

/**
 * Dismiss keyboard via Android BACK key.
 * Only sends BACK if keyboard is actually visible (checked via visualViewport).
 * Sending BACK when keyboard is hidden navigates Chrome back, destroying state.
 */
async function dismissKeyboardViaBack(driver) {
  const isVisible = await driver.executeScript(`
    const vv = window.visualViewport;
    return vv ? vv.height < window.innerHeight * 0.75 : false;
  `, []);

  if (isVisible) {
    await switchToNative(driver);
    await driver.pressKeyCode(4); // KEYCODE_BACK
    await switchToWebview(driver);
    await driver.pause(800);
  }
}

// ── Coordinate translation ──────────────────────────────────────────────

/**
 * Measure Chrome UI offset (status bar + URL bar) via touch probe.
 * Injects a one-shot touchstart listener, taps via W3C Actions,
 * computes offset = adbY - clientY * DPR.
 */
async function measureScreenOffset(driver) {
  await driver.executeScript(`
    window.__offsetProbeResult = null;
    document.addEventListener('touchstart', (e) => {
      if (e.touches.length > 0) {
        window.__offsetProbeResult = { clientY: e.touches[0].clientY };
      }
      e.preventDefault();
      e.stopImmediatePropagation();
    }, { once: true, capture: true });
  `, []);

  const probeX = 540;
  const probeY = 1200;
  await switchToNative(driver);
  await driver.performActions([{
    type: 'pointer',
    id: 'probe',
    parameters: { pointerType: 'touch' },
    actions: [
      { type: 'pointerMove', duration: 0, x: probeX, y: probeY, origin: 'viewport' },
      { type: 'pointerDown', button: 0 },
      { type: 'pause', duration: 100 },
      { type: 'pointerUp', button: 0 },
    ],
  }]);
  await driver.releaseActions();
  await driver.pause(300);
  await switchToWebview(driver);

  const result = await driver.executeScript(`
    const r = window.__offsetProbeResult;
    delete window.__offsetProbeResult;
    return r;
  `, []);

  if (result && typeof result.clientY === 'number') {
    const dpr = await driver.executeScript('return window.devicePixelRatio || 1', []);
    return Math.round(probeY - result.clientY * dpr);
  }
  return 280; // fallback: typical Pixel 7
}

/**
 * Get visible terminal bounds in screen pixels (for W3C Actions).
 * Accounts for keyboard visibility and Chrome UI offset.
 */
async function getVisibleTerminalBounds(driver) {
  const offset = await measureScreenOffset(driver);
  return driver.executeScript(`
    const el = document.querySelector('.xterm-screen') || document.querySelector('#terminal');
    if (!el) return null;
    const rect = el.getBoundingClientRect();
    const vv = window.visualViewport;
    const dpr = window.devicePixelRatio || 1;
    const vpTop = vv ? vv.offsetTop : 0;
    const vpBottom = vv ? vv.offsetTop + vv.height : window.innerHeight;
    const visTop = Math.max(rect.top, vpTop);
    const visBottom = Math.min(rect.bottom, vpBottom);
    return {
      top: Math.round(visTop * dpr) + arguments[0],
      bottom: Math.round(visBottom * dpr) + arguments[0],
      left: Math.round(rect.left * dpr),
      right: Math.round(rect.right * dpr),
      centerX: Math.round((rect.left + rect.right) / 2 * dpr),
      keyboardVisible: vv ? vv.height < window.innerHeight * 0.75 : false,
    };
  `, [offset]);
}

// ── Gesture helpers ─────────────────────────────────────────────────────

/**
 * Perform a swipe using Appium W3C Actions with intermediate pointerMove steps.
 * Goes through UiAutomator2 Instrumentation, firing real DOM touch events.
 * Multiple steps ensure the scroll handler in ime.ts receives enough touchmove
 * events to accumulate delta and compute scroll lines.
 *
 * Handles NATIVE_APP/WEBVIEW context switching automatically.
 */
async function appiumSwipe(driver, startX, startY, endX, endY, steps = 15, stepDuration = 40) {
  const actions = [
    { type: 'pointerMove', duration: 0, x: Math.round(startX), y: Math.round(startY), origin: 'viewport' },
    { type: 'pointerDown', button: 0 },
    { type: 'pause', duration: 100 },
  ];

  for (let i = 1; i <= steps; i++) {
    const f = i / steps;
    actions.push({
      type: 'pointerMove',
      duration: stepDuration,
      x: Math.round(startX + (endX - startX) * f),
      y: Math.round(startY + (endY - startY) * f),
      origin: 'viewport',
    });
  }
  actions.push({ type: 'pointerUp', button: 0 });

  await switchToNative(driver);
  await driver.performActions([{
    type: 'pointer',
    id: 'finger1',
    parameters: { pointerType: 'touch' },
    actions,
  }]);
  await driver.releaseActions();
  await switchToWebview(driver);
}

/**
 * Swipe to see older content (scroll back in history).
 * Natural scroll (default): finger moves DOWN (top to bottom).
 * Human thumb positioning: right 3/4 of terminal, slight horizontal drift.
 */
async function swipeToOlderContent(driver, bounds, marginPct = 0.15) {
  const natural = await driver.executeScript(
    "return localStorage.getItem('naturalVerticalScroll') !== 'false'", []);
  const margin = (bounds.bottom - bounds.top) * marginPct;
  const thumbX = Math.round(bounds.left + (bounds.right - bounds.left) * 0.75);
  const drift = Math.round((bounds.right - bounds.left) * 0.05);
  const [y1, y2] = natural
    ? [bounds.top + margin, bounds.bottom - margin]
    : [bounds.bottom - margin, bounds.top + margin];
  await appiumSwipe(driver, thumbX, Math.round(y1), thumbX - drift, Math.round(y2));
}

/**
 * Swipe to see newer content (scroll forward toward present).
 */
async function swipeToNewerContent(driver, bounds, marginPct = 0.15) {
  const natural = await driver.executeScript(
    "return localStorage.getItem('naturalVerticalScroll') !== 'false'", []);
  const margin = (bounds.bottom - bounds.top) * marginPct;
  const thumbX = Math.round(bounds.left + (bounds.right - bounds.left) * 0.75);
  const drift = Math.round((bounds.right - bounds.left) * 0.05);
  const [y1, y2] = natural
    ? [bounds.bottom - margin, bounds.top + margin]
    : [bounds.top + margin, bounds.bottom - margin];
  await appiumSwipe(driver, thumbX, Math.round(y1), thumbX + drift, Math.round(y2));
}

/**
 * Prime the touch pipeline with throwaway swipes.
 * Appium touches also benefit from pipeline priming, similar to ADB.
 */
async function warmupSwipes(driver, bounds) {
  const margin = Math.round((bounds.bottom - bounds.top) * 0.15);
  await appiumSwipe(driver, bounds.centerX, bounds.top + margin,
    bounds.centerX, bounds.bottom - margin, 8, 30);
  await driver.pause(300);
  await appiumSwipe(driver, bounds.centerX, bounds.bottom - margin,
    bounds.centerX, bounds.top + margin, 8, 30);
  await driver.pause(300);
}

// ── Terminal helpers ─────────────────────────────────────────────────────

/**
 * Expose appState.terminal as window.__testTerminal for buffer assertions.
 */
async function exposeTerminal(driver) {
  await driver.executeScript(`
    (async () => {
      const { appState } = await import('./modules/state.js');
      window.__testTerminal = appState.terminal;
    })();
  `, []);
  await driver.waitUntil(async () => {
    return driver.executeScript('return !!window.__testTerminal', []);
  }, { timeout: 5000, timeoutMsg: 'window.__testTerminal not set' });
}

/**
 * Read terminal screen content.
 * @param {boolean} useViewport - true: read from viewportY (plain shell), false: read from baseY (tmux)
 */
async function readScreen(driver, useViewport = false) {
  return driver.executeScript(`
    const term = window.__testTerminal;
    if (!term) return '';
    const buf = term.buffer.active;
    const startY = arguments[0] ? buf.viewportY : buf.baseY;
    const lines = [];
    for (let i = 0; i < term.rows; i++) {
      const line = buf.getLine(startY + i);
      if (line) lines.push(line.translateToString(true).trim());
    }
    return lines.filter(l => l.length > 0).join('\\n');
  `, [useViewport]);
}

/**
 * Type a command into the terminal via IME input and send Enter.
 * Character-by-character via dispatchEvent, matching the emulator fixture pattern.
 */
async function sendCommand(driver, cmd) {
  const ids = [COMPOSE_INPUT_ID, DIRECT_INPUT_ID];
  // Focus whichever input element exists
  await driver.executeScript(`
    const ids = arguments[0];
    for (const id of ids) {
      const el = document.getElementById(id);
      if (el) { el.focus(); return; }
    }
  `, [ids]);

  for (const ch of cmd) {
    await driver.executeScript(`
      const ids = arguments[1];
      for (const id of ids) {
        const el = document.getElementById(id);
        if (el) {
          el.value = arguments[0];
          el.dispatchEvent(new InputEvent('input', { bubbles: true, data: arguments[0] }));
          el.value = '';
          return;
        }
      }
    `, [ch, ids]);
  }
  // Enter
  await driver.executeScript(`
    const ids = arguments[0];
    for (const id of ids) {
      const el = document.getElementById(id);
      if (el) {
        el.value = '\\n';
        el.dispatchEvent(new InputEvent('input', { bubbles: true, data: '\\n' }));
        el.value = '';
        return;
      }
    }
  `, [ids]);
}

// ── Vault setup ─────────────────────────────────────────────────────────

/**
 * Create vault with test password. Mirrors emulatorPage fixture's vault setup.
 */
async function setupVault(driver) {
  const modalVisible = await driver.executeScript(`
    const overlay = document.getElementById('vaultSetupOverlay');
    return overlay && !overlay.classList.contains('hidden');
  `, []);

  if (!modalVisible) {
    // Vault might already exist from shared context
    const hasVault = await driver.executeScript(
      "return !!localStorage.getItem('vaultMeta')", []);
    if (!hasVault) {
      throw new Error('setupVault: modal not visible and no vault in localStorage');
    }
    return;
  }

  await driver.executeScript(`
    document.getElementById('vaultNewPw').value = 'test';
    document.getElementById('vaultConfirmPw').value = 'test';
    const cb = document.getElementById('vaultEnableBio');
    if (cb) cb.checked = false;
  `, []);

  // Trigger input events so the form recognizes values
  await driver.executeScript(`
    ['vaultNewPw', 'vaultConfirmPw'].forEach(id => {
      const el = document.getElementById(id);
      if (el) el.dispatchEvent(new Event('input', { bubbles: true }));
    });
  `, []);

  await dismissKeyboardViaBack(driver);
  await driver.pause(300);

  await driver.executeScript(
    "document.getElementById('vaultSetupCreate')?.click()", []);

  await driver.waitUntil(async () => {
    return driver.executeScript(`
      const o = document.getElementById('vaultSetupOverlay');
      return !o || o.classList.contains('hidden');
    `, []);
  }, { timeout: 5000, timeoutMsg: 'Vault overlay did not dismiss' });
}

// ── SSH connection ──────────────────────────────────────────────────────

/**
 * Connect to real SSH server through the MobiSSH bridge.
 * Assumes driver is in WEBVIEW context and vault is set up.
 */
async function setupRealSSHConnection(driver) {
  // Wait for terminal element
  await driver.waitUntil(async () => {
    return driver.executeScript(
      "return !!document.querySelector('.xterm-screen')", []);
  }, { timeout: 30000, interval: 500, timeoutMsg: 'Terminal .xterm-screen not found' });

  // Enable private hosts and inject WS spy
  await driver.executeScript(`
    localStorage.setItem('allowPrivateHosts', 'true');
    window.__mockWsSpy = [];
    const OrigWS = window.WebSocket;
    window.WebSocket = class extends OrigWS {
      send(data) { window.__mockWsSpy.push(data); super.send(data); }
    };
  `, []);

  // Navigate to connect panel
  await driver.executeScript(
    "document.querySelector('[data-panel=\"connect\"]')?.click()", []);
  await driver.pause(1000);

  // Fill connection form via executeScript (more reliable than WebDriverIO setValue
  // which requires element focus + Appium typing, and may conflict with Chrome autocomplete)
  await driver.executeScript(`
    const h = document.getElementById('host');
    const p = document.getElementById('port');
    const u = document.getElementById('remote_a');
    const pw = document.getElementById('remote_c');
    if (h) { h.value = arguments[0]; h.dispatchEvent(new Event('input', { bubbles: true })); }
    if (p) { p.value = arguments[1]; p.dispatchEvent(new Event('input', { bubbles: true })); }
    if (u) { u.value = arguments[2]; u.dispatchEvent(new Event('input', { bubbles: true })); }
    if (pw) { pw.value = arguments[3]; pw.dispatchEvent(new Event('input', { bubbles: true })); }
  `, [SSHD_HOST, String(SSHD_PORT), TEST_USER, TEST_PASS]);
  await driver.pause(500);

  // Submit
  await driver.executeScript(
    "document.querySelector('#connectForm button[type=\"submit\"]')?.click()", []);

  // Accept host key dialog (may not appear if key already trusted from earlier test)
  await driver.waitUntil(async () => {
    return driver.executeScript(`
      const btn = document.querySelector('.hostkey-accept');
      const hostKeyVisible = btn && btn.offsetParent !== null;
      const connected = (window.__mockWsSpy || []).some(s => {
        try { return JSON.parse(s).type === 'resize'; } catch { return false; }
      });
      return hostKeyVisible || connected;
    `, []);
  }, { timeout: 15000, interval: 500, timeoutMsg: 'Neither host key dialog nor connection appeared' });

  // Click accept if the host key dialog is showing
  const hostKeyVisible = await driver.executeScript(`
    const btn = document.querySelector('.hostkey-accept');
    return btn && btn.offsetParent !== null;
  `, []);
  if (hostKeyVisible) {
    await driver.executeScript('document.activeElement?.blur()', []);
    await driver.pause(500);
    await dismissKeyboardViaBack(driver);
    await driver.pause(300);
    await driver.executeScript(
      "document.querySelector('.hostkey-accept')?.click()", []);
    await driver.pause(1000);
  }

  // Wait for SSH connection (resize message = shell ready)
  await driver.waitUntil(async () => {
    return driver.executeScript(`
      return (window.__mockWsSpy || []).some(s => {
        try { return JSON.parse(s).type === 'resize'; } catch { return false; }
      });
    `, []);
  }, { timeout: 15000, interval: 500, timeoutMsg: 'SSH connection did not complete (no resize msg)' });

  // Ensure terminal panel is active
  await driver.executeScript(
    "document.querySelector('[data-panel=\"terminal\"]')?.click()", []);
  await driver.pause(500);
}

// ── Screenshot helper ───────────────────────────────────────────────────

/**
 * Attach Appium screenshot to Playwright test report.
 */
async function attachScreenshot(driver, testInfo, name) {
  const png = await driver.takeScreenshot();
  await testInfo.attach(name, {
    body: Buffer.from(png, 'base64'),
    contentType: 'image/png',
  });
}

// ── Playwright fixtures ─────────────────────────────────────────────────

const test = base.extend({
  /**
   * Worker-scoped Appium session — ONE session for all tests in a worker.
   * Avoids UiAutomator2 instrumentation crash from repeated session create/destroy.
   * @private — tests should use `driver`, not `_workerDriver`.
   */
  // eslint-disable-next-line no-empty-pattern
  _workerDriver: [async ({}, use) => {
    const driver = await createDriver();
    try {
      await use(driver);
    } finally {
      try { await driver.deleteSession(); } catch { /* best effort */ }
    }
  }, { scope: 'worker' }],

  /**
   * Test-scoped driver: navigates to BASE_URL, dismisses dialogs, and
   * switches to webview before each test. Screenshots on failure.
   * Reuses the worker-scoped session underneath.
   */
  driver: async ({ _workerDriver }, use, testInfo) => {
    const driver = _workerDriver;

    // Start per-test screen recording if APPIUM_RECORDING_DIR is set.
    // Filename: sanitized test title (spaces → dashes, special chars removed).
    let recordingFile = '';
    if (RECORDING_DIR) {
      const safeName = testInfo.title
        .replace(/[^a-zA-Z0-9_-]+/g, '-')
        .replace(/-+/g, '-')
        .replace(/^-|-$/g, '')
        .substring(0, 80);
      recordingFile = path.join(RECORDING_DIR, `${safeName}.webm`);
      try {
        execSync(
          `adb emu screenrecord start --size 540x1200 --bit-rate 1000000 --fps 12 "${recordingFile}"`,
          { timeout: 5000 },
        );
      } catch { /* best effort — recording is optional */ }
    }

    await driver.url(BASE_URL);
    await driver.pause(2000);
    await dismissNativeDialogs(driver);
    await switchToWebview(driver);

    await use(driver);

    // Stop per-test recording before teardown.
    if (recordingFile) {
      try {
        execSync('adb emu screenrecord stop', { timeout: 5000 });
      } catch { /* best effort */ }
      // Attach recording to Playwright report for easy review.
      try {
        const fs = require('fs');
        if (fs.existsSync(recordingFile)) {
          await testInfo.attach('screen-recording', {
            path: recordingFile,
            contentType: 'video/webm',
          });
        }
      } catch { /* best effort */ }
    }

    if (testInfo.status !== testInfo.expectedStatus) {
      try {
        const screenshot = await driver.takeScreenshot();
        await testInfo.attach('appium-screenshot', {
          body: Buffer.from(screenshot, 'base64'),
          contentType: 'image/png',
        });
      } catch { /* best effort */ }
    }
  },

  /**
   * Helper functions exposed as a fixture for convenience.
   */
  // eslint-disable-next-line no-empty-pattern
  appium: async ({}, use) => {
    await use({
      switchToWebview,
      switchToNative,
      dismissNativeDialogs,
      BASE_URL,
    });
  },

  /**
   * sshServer — worker-scoped fixture.
   * Ensures Docker test-sshd container is running.
   */
  // eslint-disable-next-line no-empty-pattern
  sshServer: [async ({}, use) => {
    ensureTestSshd();
    await use({ host: SSHD_HOST, port: SSHD_PORT, user: TEST_USER, password: TEST_PASS });
  }, { scope: 'worker' }],
});

module.exports = {
  test, expect,
  switchToWebview, switchToNative, dismissNativeDialogs,
  measureScreenOffset, getVisibleTerminalBounds,
  appiumSwipe, swipeToOlderContent, swipeToNewerContent, warmupSwipes,
  setupRealSSHConnection, setupVault, sendCommand,
  dismissKeyboardViaBack, exposeTerminal,
  readScreen, attachScreenshot,
  BASE_URL, SSHD_HOST, SSHD_PORT, TEST_USER, TEST_PASS,
};
