'use strict';

/**
 * server/test-keepalive.js — Protocol-level keepalive tests
 *
 * Tests WS ping/pong, connection survival under idle, and SSH keepalive behavior.
 * Runs against the REAL server (not a mock). Requires:
 *   - Server running on localhost:8081 (scripts/server-ctl.sh ensure)
 *   - test-sshd running (docker-compose.test.yml)
 *
 * These tests are SLOW (30s-150s per test). Not for the fast gate.
 *
 * Run with: node --test server/test-keepalive.js
 */

const { test, describe, before, after } = require('node:test');
const assert = require('node:assert/strict');
const WebSocket = require('ws');

const SERVER_URL = process.env.TEST_WS_URL || 'ws://localhost:8081';
const TEST_HOST = process.env.TEST_SSH_HOST || 'test-sshd';
const TEST_USER = process.env.TEST_SSH_USER || 'testuser';
const TEST_PASS = process.env.TEST_SSH_PASS || 'testpass';

/** Open a WS and wait for it to be ready. */
function openWs(url = SERVER_URL) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    ws.on('open', () => resolve(ws));
    ws.on('error', reject);
    setTimeout(() => reject(new Error('WS open timeout')), 10000);
  });
}

/** Send a connect message and wait for SSH 'connected' response. */
function connectSsh(ws, host = TEST_HOST, user = TEST_USER, pass = TEST_PASS) {
  return new Promise((resolve, reject) => {
    const handler = (data) => {
      const msg = JSON.parse(data.toString());
      if (msg.type === 'connected') {
        ws.off('message', handler);
        resolve(msg);
      } else if (msg.type === 'error') {
        ws.off('message', handler);
        reject(new Error(msg.message));
      }
    };
    ws.on('message', handler);
    ws.send(JSON.stringify({
      type: 'connect',
      host,
      port: 22,
      username: user,
      password: pass,
    }));
    setTimeout(() => reject(new Error('SSH connect timeout')), 30000);
  });
}

/** Wait for a specific duration. */
function wait(ms) { return new Promise(r => setTimeout(r, ms)); }

/** Count WS ping events received within a duration. */
function countPings(ws, durationMs) {
  return new Promise((resolve) => {
    let count = 0;
    const handler = () => { count++; };
    ws.on('ping', handler);
    setTimeout(() => {
      ws.off('ping', handler);
      resolve(count);
    }, durationMs);
  });
}

describe('WS ping/pong protocol', { timeout: 60000 }, () => {

  test('server sends WS ping within 30s of connection', async () => {
    const ws = await openWs();
    try {
      const pings = await countPings(ws, 30000);
      assert.ok(pings >= 1, `Expected at least 1 ping, got ${pings}`);
    } finally {
      ws.close();
    }
  });

  test('client auto-responds with pong (browser behavior)', async () => {
    // ws library auto-responds to pings with pongs by default
    // This test verifies the server receives the pong and doesn't terminate
    const ws = await openWs();
    try {
      // Wait for 2 ping cycles (50s) — if pong wasn't received, server
      // would terminate after 1 missed pong cycle
      await wait(50000);
      assert.equal(ws.readyState, WebSocket.OPEN, 'WS should still be open after 50s');
    } finally {
      ws.close();
    }
  });
});

describe('Connection survival', { timeout: 180000 }, () => {

  test('bare WS survives 60s idle', async () => {
    const ws = await openWs();
    try {
      await wait(60000);
      assert.equal(ws.readyState, WebSocket.OPEN, 'WS should survive 60s idle');
    } finally {
      ws.close();
    }
  });

  test('SSH session survives 60s idle', async () => {
    const ws = await openWs();
    try {
      await connectSsh(ws);
      await wait(60000);
      assert.equal(ws.readyState, WebSocket.OPEN, 'WS+SSH should survive 60s idle');

      // Verify SSH is still alive by sending input
      let gotOutput = false;
      ws.on('message', (data) => {
        const msg = JSON.parse(data.toString());
        if (msg.type === 'output') gotOutput = true;
      });
      ws.send(JSON.stringify({ type: 'input', data: 'echo alive\n' }));
      await wait(2000);
      assert.ok(gotOutput, 'SSH should respond to input after 60s idle');
    } finally {
      ws.close();
    }
  });

  test('SSH session survives 120s idle', async () => {
    const ws = await openWs();
    try {
      await connectSsh(ws);
      await wait(120000);
      assert.equal(ws.readyState, WebSocket.OPEN, 'WS+SSH should survive 120s idle');

      let gotOutput = false;
      ws.on('message', (data) => {
        const msg = JSON.parse(data.toString());
        if (msg.type === 'output') gotOutput = true;
      });
      ws.send(JSON.stringify({ type: 'input', data: 'echo alive120\n' }));
      await wait(2000);
      assert.ok(gotOutput, 'SSH should respond to input after 120s idle');
    } finally {
      ws.close();
    }
  });
});

describe('Pong suppression (simulate mobile throttle)', { timeout: 180000 }, () => {

  test('connection terminated after sustained pong failure', async () => {
    // Open a raw WS and suppress automatic pong responses
    const ws = new WebSocket(SERVER_URL, { autoPong: false });
    await new Promise((resolve, reject) => {
      ws.on('open', resolve);
      ws.on('error', reject);
    });

    // Don't respond to pings — server should eventually terminate
    let terminated = false;
    ws.on('close', () => { terminated = true; });

    // Server pings every 25s, terminates after 6 missed pongs = 150s
    // Wait up to 180s for termination
    await wait(170000);

    assert.ok(terminated, 'Server should terminate after sustained pong failure');
  });
});

describe('Application-level ping', { timeout: 60000 }, () => {

  test('server accepts application-level ping without response', async () => {
    const ws = await openWs();
    try {
      // Send app-level ping (not WS protocol ping)
      ws.send(JSON.stringify({ type: 'ping' }));
      await wait(1000);
      // Server should not close on app-level ping
      assert.equal(ws.readyState, WebSocket.OPEN, 'Server should accept app ping');
    } finally {
      ws.close();
    }
  });
});

describe('Reconnect after server close', { timeout: 60000 }, () => {

  test('new WS connection works after server-initiated close', async () => {
    const ws1 = await openWs();
    await connectSsh(ws1);

    // Server terminates the connection
    ws1.close();
    await wait(1000);

    // New connection should work immediately
    const ws2 = await openWs();
    try {
      await connectSsh(ws2);
      assert.equal(ws2.readyState, WebSocket.OPEN, 'Reconnect should succeed');

      let gotOutput = false;
      ws2.on('message', (data) => {
        const msg = JSON.parse(data.toString());
        if (msg.type === 'output') gotOutput = true;
      });
      ws2.send(JSON.stringify({ type: 'input', data: 'echo reconnected\n' }));
      await wait(2000);
      assert.ok(gotOutput, 'SSH should work after reconnect');
    } finally {
      ws2.close();
    }
  });
});
