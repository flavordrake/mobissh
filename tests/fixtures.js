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

module.exports = { test, expect };
