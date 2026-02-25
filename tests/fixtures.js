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
 * ensureTestVault — create and unlock a test vault in the browser
 *
 * Pre-creates a vault with password 'test' so that ensureVaultKeyWithUI()
 * finds appState.vaultKey already set and never shows the setup modal.
 * Must be called after page.goto() and before any profile save / connect.
 */
async function ensureTestVault(page) {
  await page.evaluate(async () => {
    // Import the vault module dynamically from the already-loaded app
    const { createVault } = await import('./modules/vault.js');
    await createVault('test', false);
  });
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
  await page.locator('#username').fill('testuser');
  await page.locator('#password').fill('testpass');

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
  await page.waitForSelector('#panel-terminal.active', { timeout: 5000 });
  await page.locator('#imeInput').focus().catch(() => {});
  await page.waitForTimeout(100);
}

module.exports = { test, expect, setupConnected, ensureTestVault };
