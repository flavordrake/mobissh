/**
 * tests/fixtures.js
 *
 * Shared Playwright fixtures for MobiSSH tests.
 *
 * mockSshServer fixture
 * ─────────────────────
 * Spins up a lightweight WebSocket server on a free port that simulates
 * the SSH bridge's wire protocol. On receiving a `connect` message it
 * immediately sends back `connected` + a fake shell prompt.
 *
 * Usage in tests:
 *   import { test, expect } from './fixtures.js';
 *   test('my test', async ({ page, mockSshServer }) => { … });
 */

const { test: base, expect } = require('@playwright/test');
const { WebSocketServer } = require('ws');
const { createServer } = require('net');

// ── Input element helpers ────────────────────────────────────────────────────
// Centralises element IDs and expected properties so tests don't hardcode them.
// When the input strategy changes (type, id, approach), update here only.

/** ID of the compose-mode textarea (IME/swipe input). */
const COMPOSE_INPUT_ID = 'imeInput';
/** ID of the direct-mode hidden input (char-by-char, no IME). */
const DIRECT_INPUT_ID  = 'directInput';
/** Expected `type` attribute of the direct-mode input. */
const DIRECT_INPUT_TYPE = 'password';

/** Return the active IME input element ID based on current mode. */
function activeInputSelector(page) {
  return page.evaluate((ids) =>
    document.getElementById(ids.compose) === document.activeElement
      ? ids.compose : ids.direct,
    { compose: COMPOSE_INPUT_ID, direct: DIRECT_INPUT_ID }
  );
}

// Find a random free TCP port
function getFreePort() {
  return new Promise((resolve, reject) => {
    const srv = createServer();
    srv.listen(0, () => {
      const { port } = srv.address();
      srv.close(() => resolve(port));
    });
    srv.on('error', reject);
  });
}

const test = base.extend({
  /**
   * page — override built-in page fixture
   *
   * Auto-dismisses the startup vault setup modal on every navigation.
   * The modal blocks all interaction until the user creates a vault.
   * In tests, we cancel it immediately so boot completes and tests can run.
   * Tests that need a real vault call ensureTestVault() after navigation.
   */
  page: async ({ page }, use) => {
    // Seed vaultMeta before any page code runs. This runs LAST among all
    // addInitScript calls (added here after test's beforeEach scripts).
    // But tests that clear localStorage may wipe it — so we also add a
    // fallback: a DOMContentLoaded listener that clicks Cancel if the
    // vault modal appears.
    await page.addInitScript(() => {
      if (!localStorage.getItem('vaultMeta')) {
        localStorage.setItem('vaultMeta', JSON.stringify({
          salt: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
          dekPw: { iv: 'AAAAAAAAAAAAAAA=', ct: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' },
        }));
      }
      // Fallback: if the vault modal appears (e.g. because another
      // addInitScript cleared localStorage after the seed), auto-dismiss it.
      document.addEventListener('DOMContentLoaded', () => {
        const obs = new MutationObserver(() => {
          const overlay = document.getElementById('vaultSetupOverlay');
          if (overlay && !overlay.classList.contains('hidden')) {
            const cancel = document.getElementById('vaultSetupCancel');
            if (cancel) { cancel.click(); obs.disconnect(); }
          }
        });
        obs.observe(document.body || document.documentElement, { childList: true, subtree: true, attributes: true });
        // Also check immediately
        setTimeout(() => {
          const overlay = document.getElementById('vaultSetupOverlay');
          if (overlay && !overlay.classList.contains('hidden')) {
            const cancel = document.getElementById('vaultSetupCancel');
            if (cancel) { cancel.click(); obs.disconnect(); }
          }
        }, 100);
      });
    });
    await use(page);
  },

  /**
   * mockSshServer — fixture
   *
   * Provides an object with:
   *   .port          — TCP port the mock WS server listens on
   *   .messages      — array of parsed JSON messages received from the page
   *   .sendToPage(obj) — send a JSON message to the connected page
   */
  // eslint-disable-next-line no-empty-pattern
  mockSshServer: async ({}, use) => {
    const port = await getFreePort();
    const messages = [];
    let activeSockets = [];

    const wss = new WebSocketServer({ port });

    wss.on('connection', (ws) => {
      activeSockets.push(ws);

      ws.on('message', (raw) => {
        let msg;
        try { msg = JSON.parse(raw.toString()); } catch (_) { return; }
        messages.push(msg);

        // Auto-respond to connect: simulate successful SSH session
        if (msg.type === 'connect') {
          setTimeout(() => {
            if (ws.readyState === ws.OPEN) {
              ws.send(JSON.stringify({ type: 'connected' }));
              ws.send(JSON.stringify({
                type: 'output',
                data: '\r\nMobiSSH mock server ready\r\nmock-shell$ ',
              }));
            }
          }, 80);
        }
      });

      ws.on('close', () => {
        activeSockets = activeSockets.filter((s) => s !== ws);
      });
    });

    const fixture = {
      port,
      messages,
      sendToPage(obj) {
        const payload = JSON.stringify(obj);
        activeSockets.forEach((s) => {
          if (s.readyState === s.OPEN) s.send(payload);
        });
      },
    };

    await use(fixture);

    // Cleanup
    activeSockets.forEach((s) => { try { s.terminate(); } catch (_) {} });
    await new Promise((resolve) => wss.close(resolve));
  },
});

/**
 * setupConnected — shared helper
 *
 * Navigates to the app, fills the connect form with mock-server credentials,
 * submits, waits for the mock SSH server to respond with `connected`, then
 * leaves the terminal panel active and IME textarea focused.
 *
 * The WS spy (window.__mockWsSpy) is injected before navigation so every
 * outbound WebSocket message is captured and can be queried in tests.
 *
 * @param {import('@playwright/test').Page} page
 * @param {{ port: number }} mockSshServer - fixture with the mock WS port
 */
/**
 * dismissVaultModal — dismiss the startup vault setup modal
 *
 * On first launch (clean localStorage), the app shows a vault setup modal
 * that blocks all interaction. Click Cancel to dismiss it and unblock boot.
 * No-op if the modal isn't visible.
 */
async function dismissVaultModal(page) {
  try {
    const cancelBtn = page.locator('#vaultSetupCancel');
    await cancelBtn.waitFor({ state: 'visible', timeout: 2000 });
    await cancelBtn.click();
    await page.waitForSelector('#vaultSetupOverlay.hidden', { timeout: 2000 });
  } catch { /* modal not present — vault already exists */ }
}

/**
 * ensureTestVault — create and unlock a test vault in the browser
 *
 * Pre-creates a vault with password 'test' so that ensureVaultKeyWithUI()
 * finds appState.vaultKey already set and never shows the setup modal.
 * Must be called after page.goto() and before any profile save / connect.
 *
 * Also dismisses the startup vault modal (which blocks boot) by clicking Cancel.
 * The vault is already created programmatically, so Cancel just unblocks the UI.
 */
async function ensureTestVault(page) {
  await page.evaluate(async () => {
    // Import the vault module dynamically from the already-loaded app
    const { createVault } = await import('./modules/vault.js');
    await createVault('test', false);
  });
  // Dismiss the startup vault setup modal to unblock boot
  await dismissVaultModal(page);
}

async function setupConnected(page, mockSshServer) {
  // Inject WS spy before any app code runs — wraps window.WebSocket.send
  await page.addInitScript(() => {
    window.__mockWsSpy = [];
    const OrigWS = window.WebSocket;
    window.WebSocket = class extends OrigWS {
      send(data) {
        window.__mockWsSpy.push(data);
        super.send(data);
      }
    };
  });

  // Clear localStorage (no profiles → app lands on Terminal tab)
  await page.addInitScript(() => { localStorage.clear(); });

  await page.goto('./');
  await page.waitForSelector('.xterm-screen', { timeout: 8000 });

  // Create and unlock a test vault before any profile operations
  await ensureTestVault(page);

  // Set WS URL to the mock server BEFORE connecting
  await page.evaluate((port) => {
    localStorage.setItem('wsUrl', `ws://localhost:${port}`);
  }, mockSshServer.port);

  // Navigate to Connect tab and fill the form
  await page.locator('[data-panel="connect"]').click();
  await page.locator('#host').fill('mock-host');
  await page.locator('#port').fill('22');
  await page.locator('#remote_a').fill('testuser');
  await page.locator('#remote_c').fill('testpass');

  // Submit — calls saveProfile() then connect()
  await page.locator('#connectForm button[type="submit"]').click();

  // Wait until the app sends a `resize` message — this is the first message sent
  // after the app receives `{type: "connected"}` from the mock server.
  await page.waitForFunction(() => {
    return (window.__mockWsSpy || []).some((s) => {
      try { return JSON.parse(s).type === 'resize'; } catch (_) { return false; }
    });
  }, null, { timeout: 10_000 });

  // The app calls switchToTerminal() on form submit, then on receiving `connected`
  // it calls focusIME() automatically and hides the tab bar (#36).
  // Default is Direct mode (#146), so focus whichever input is active.
  await page.waitForSelector('#panel-terminal.active', { timeout: 5000 });
  const inputId = await activeInputSelector(page);
  await page.locator(`#${inputId}`).focus().catch(() => {});
  await page.waitForTimeout(100);
}

module.exports = {
  test, expect, setupConnected, ensureTestVault,
  COMPOSE_INPUT_ID, DIRECT_INPUT_ID, DIRECT_INPUT_TYPE, activeInputSelector,
};
