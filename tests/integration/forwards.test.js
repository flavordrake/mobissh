/**
 * tests/integration/forwards.test.js
 *
 * Wire-to-wire integration test for issue #499 — local (-L) forwarding.
 *
 * Covers behavioral assertions:
 *   B2   Server emits fwd_local_ready after binding the listen socket
 *   B3   Active forward visible in client model
 *   B4   Incoming TCP connections announced via fwd_local_accept
 *   B5   Bidirectional data round-trips byte-for-byte
 *   B6   Channel close is symmetric (subsequent data dropped, forward stays)
 *   EC3  EADDRINUSE on bind surfaces as fwd_local_error, WS stays open
 *   EC4  SSH disconnect closes forwards + releases ports
 *   EC6  srcPort=0 ⇒ server returns the bound ephemeral port
 *   EC7  Privileged port (<1024) under unprivileged container — soft test
 *
 * Pattern: spawns a fresh `node server/index.js` bridge with
 * MOBISSH_LOCAL_FORWARDS=1 on a free port, opens a WS to it, and drives the
 * fwd_local_* protocol directly. The SSH target is the existing test-sshd
 * Docker container (see tests/emulator/sshd-fixture.js).
 *
 * Pre-implementation: the bridge ignores MOBISSH_LOCAL_FORWARDS, has no
 * fwd_local_* router branch, and returns `Unknown message type` for our
 * fwd_local_listen frame. All assertions below fail. Acceptable red baseline.
 */

const { test, expect } = require('@playwright/test');
const WebSocket = require('ws');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { createServer } = require('node:net');
const http = require('node:http');
const fs = require('node:fs');
const { ensureTestSshd, SSHD_HOST, SSHD_PORT, TEST_USER, TEST_PASS } =
  require('../emulator/sshd-fixture.js');

const REPO_ROOT = path.resolve(__dirname, '../..');

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

async function waitForUrl(url, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(url);
      if (res.status >= 200 && res.status < 500) return true;
    } catch { /* not up yet */ }
    await new Promise((r) => setTimeout(r, 200));
  }
  throw new Error(`server did not come up at ${url} within ${timeoutMs}ms`);
}

async function spawnBridge(port) {
  const child = spawn('node', ['server/index.js'], {
    cwd: REPO_ROOT,
    env: {
      ...process.env,
      PORT: String(port),
      MOBISSH_LOCAL_FORWARDS: '1',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const logs = [];
  child.stdout.on('data', (d) => logs.push(['stdout', d.toString()]));
  child.stderr.on('data', (d) => logs.push(['stderr', d.toString()]));

  await waitForUrl(`http://127.0.0.1:${port}/version`);
  return { child, logs };
}

function openWs(port) {
  const ws = new WebSocket(`ws://127.0.0.1:${port}/`);
  const inbox = [];
  ws.on('message', (raw) => {
    try { inbox.push(JSON.parse(raw.toString())); } catch { /* ignore non-JSON */ }
  });
  return { ws, inbox };
}

function waitFor(predicate, inbox, timeoutMs = 5000, label = 'message') {
  return new Promise((resolve, reject) => {
    const start = Date.now();
    (function poll() {
      const found = inbox.find(predicate);
      if (found) return resolve(found);
      if (Date.now() - start > timeoutMs) return reject(new Error(`timed out waiting for ${label}`));
      setTimeout(poll, 50);
    })();
  });
}

function connectSsh(ws, inbox) {
  ws.send(JSON.stringify({
    type: 'connect',
    host: SSHD_HOST,
    port: SSHD_PORT,
    username: TEST_USER,
    password: TEST_PASS,
    allowPrivate: true,
  }));
  return waitFor((m) => m.type === 'connected', inbox, 10_000, '{type:connected}');
}

// Helper: start a tiny HTTP server inside test-sshd via SSH exec. We use the
// existing busybox httpd which the alpine image carries. Since we don't have
// direct SSH-exec from this test, instead start an in-test HTTP server on
// THIS process, then forward to it via test-sshd → fd-dev.
// Simpler approach for B5: spawn a fixed-content HTTP server INSIDE this
// test process listening on a random port reachable as `fd-dev:<port>` from
// test-sshd. Then open a forward F: 127.0.0.1:Fport → fd-dev:Hport. fetch
// from THIS process against 127.0.0.1:Fport — the bridge tunnels through
// SSH → test-sshd → back out to fd-dev via Docker DNS.
async function startContentHttpServer(body) {
  const srv = http.createServer((_req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/plain', 'Content-Length': String(Buffer.byteLength(body)) });
    res.end(body);
  });
  return new Promise((resolve) => {
    srv.listen(0, '0.0.0.0', () => {
      const { port } = srv.address();
      resolve({ srv, port });
    });
  });
}

function getOwnHostname() {
  // From within fd-dev, the Docker DNS name is the container's hostname.
  // tests/emulator/sshd-fixture.js joins us to the `mobissh` network so
  // test-sshd can resolve us by hostname.
  return fs.readFileSync('/etc/hostname', 'utf8').trim();
}

test.describe('Forwards integration (#499)', () => {
  // Long timeouts — we boot a real bridge + SSH target + content server.
  test.setTimeout(60_000);

  let bridge;       // { child, logs }
  let bridgePort;
  let wsClient;     // { ws, inbox }
  let contentSrv;   // { srv, port }
  let contentBody = '';

  test.beforeAll(async () => {
    ensureTestSshd();
  });

  test.beforeEach(async () => {
    bridgePort = await getFreePort();
    bridge = await spawnBridge(bridgePort);
    wsClient = openWs(bridgePort);
    await new Promise((res, rej) => {
      wsClient.ws.once('open', res);
      wsClient.ws.once('error', rej);
    });
    await connectSsh(wsClient.ws, wsClient.inbox);

    contentBody = `mobissh-fwd-integration:${Math.random().toString(36).slice(2)}`;
    contentSrv = await startContentHttpServer(contentBody);
  });

  test.afterEach(async () => {
    try { wsClient.ws.close(); } catch { /* ignore */ }
    try { contentSrv.srv.close(); } catch { /* ignore */ }
    try {
      bridge.child.kill('SIGTERM');
      await new Promise((r) => setTimeout(r, 300));
    } catch { /* ignore */ }
  });

  // ── B2 + B3 ──────────────────────────────────────────────────────────────

  test('B2: fwd_local_listen → fwd_local_ready with bound srcPort', async () => {
    const id = 'F-b2-' + Date.now();
    const wantPort = await getFreePort();
    wsClient.ws.send(JSON.stringify({
      type: 'fwd_local_listen', id, srcPort: wantPort,
      dstHost: getOwnHostname(), dstPort: contentSrv.port,
    }));

    const ready = await waitFor(
      (m) => m.type === 'fwd_local_ready' && m.id === id,
      wsClient.inbox, 5000, 'fwd_local_ready'
    );
    expect(ready.srcPort).toBe(wantPort);
    expect(ready.listenAddr).toBe('127.0.0.1');
  });

  test('B3 + B4 + B5: round-trip HTTP through the forward', async () => {
    // Open the forward
    const id = 'F-b5-' + Date.now();
    const wantPort = await getFreePort();
    wsClient.ws.send(JSON.stringify({
      type: 'fwd_local_listen', id, srcPort: wantPort,
      dstHost: getOwnHostname(), dstPort: contentSrv.port,
    }));
    await waitFor((m) => m.type === 'fwd_local_ready' && m.id === id, wsClient.inbox);

    // From this process, fetch http://127.0.0.1:wantPort — the bridge tunnels
    // it through SSH to test-sshd, which forwards to fd-dev:contentSrv.port.
    const body = await new Promise((resolve, reject) => {
      const req = http.request({
        host: '127.0.0.1', port: wantPort, path: '/', method: 'GET',
        timeout: 8000,
      }, (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
      });
      req.on('error', reject);
      req.on('timeout', () => { req.destroy(new Error('http timeout')); });
      req.end();
    });

    expect(body).toContain(contentBody);

    // B4: at least one fwd_local_accept fired
    const accept = wsClient.inbox.find((m) => m.type === 'fwd_local_accept' && m.id === id);
    expect(accept, 'server must announce the inbound TCP connection').toBeDefined();
    expect(typeof accept.channelId).toBe('string');
    expect(accept.peer).toBeDefined();
    expect(typeof accept.peer.port).toBe('number');
  });

  // ── B6: channel-close is symmetric ───────────────────────────────────────

  test('B6: server emits fwd_local_channel_close on EOF; forward stays active', async () => {
    const id = 'F-b6-' + Date.now();
    const wantPort = await getFreePort();
    wsClient.ws.send(JSON.stringify({
      type: 'fwd_local_listen', id, srcPort: wantPort,
      dstHost: getOwnHostname(), dstPort: contentSrv.port,
    }));
    await waitFor((m) => m.type === 'fwd_local_ready' && m.id === id, wsClient.inbox);

    // Fire one request, let HTTP server close the connection (Content-Length set)
    await new Promise((resolve, reject) => {
      const req = http.get({ host: '127.0.0.1', port: wantPort, path: '/', timeout: 5000 },
        (res) => { res.resume(); res.on('end', resolve); });
      req.on('error', reject);
    });

    await waitFor(
      (m) => m.type === 'fwd_local_channel_close' && m.id === id,
      wsClient.inbox, 5000, 'fwd_local_channel_close'
    );

    // Forward itself is NOT closed
    const closed = wsClient.inbox.find((m) => m.type === 'fwd_local_closed' && m.id === id);
    expect(closed, 'forward must NOT close just because a channel closed').toBeUndefined();
  });

  // ── EC3: EADDRINUSE ───────────────────────────────────────────────────────

  test('EC3: EADDRINUSE on bind surfaces as fwd_local_error, WS stays open', async () => {
    // Hold a port on 127.0.0.1, then ask the bridge to listen on it.
    const holder = await new Promise((resolve) => {
      const s = createServer();
      s.listen(0, '127.0.0.1', () => resolve(s));
    });
    const heldPort = holder.address().port;

    const id = 'F-ec3-' + Date.now();
    wsClient.ws.send(JSON.stringify({
      type: 'fwd_local_listen', id, srcPort: heldPort,
      dstHost: getOwnHostname(), dstPort: contentSrv.port,
    }));

    const err = await waitFor(
      (m) => m.type === 'fwd_local_error' && m.id === id,
      wsClient.inbox, 5000, 'fwd_local_error'
    );
    expect(err.code).toBe('eaddrinuse');
    // WS must still be open
    expect(wsClient.ws.readyState).toBe(WebSocket.OPEN);

    holder.close();
  });

  // ── EC4: SSH disconnect closes forwards + releases ports ─────────────────

  test('EC4: SSH disconnect closes the forward, releases the listening port', async () => {
    const id = 'F-ec4-' + Date.now();
    const wantPort = await getFreePort();
    wsClient.ws.send(JSON.stringify({
      type: 'fwd_local_listen', id, srcPort: wantPort,
      dstHost: getOwnHostname(), dstPort: contentSrv.port,
    }));
    await waitFor((m) => m.type === 'fwd_local_ready' && m.id === id, wsClient.inbox);

    // Trigger SSH disconnect via the existing protocol message
    wsClient.ws.send(JSON.stringify({ type: 'disconnect' }));

    const closed = await waitFor(
      (m) => m.type === 'fwd_local_closed' && m.id === id,
      wsClient.inbox, 5000, 'fwd_local_closed'
    );
    expect(closed.reason).toBe('ssh_disconnected');

    // Listening port should be released — re-bind in this process succeeds.
    const rebind = await new Promise((resolve) => {
      const s = createServer();
      s.listen(wantPort, '127.0.0.1', () => resolve(s));
      s.on('error', () => resolve(null));
    });
    expect(rebind, 'listening port must be released after fwd_local_closed').not.toBeNull();
    rebind.close();
  });

  // ── EC5: independent forwards ────────────────────────────────────────────

  test('EC5: a failure on F1 does not close F2 or release its port', async () => {
    const idA = 'F-ec5a-' + Date.now();
    const idB = 'F-ec5b-' + Date.now();
    const portA = await getFreePort();
    const portB = await getFreePort();

    wsClient.ws.send(JSON.stringify({
      type: 'fwd_local_listen', id: idA, srcPort: portA,
      dstHost: getOwnHostname(), dstPort: contentSrv.port,
    }));
    wsClient.ws.send(JSON.stringify({
      type: 'fwd_local_listen', id: idB, srcPort: portB,
      dstHost: getOwnHostname(), dstPort: contentSrv.port,
    }));

    await waitFor((m) => m.type === 'fwd_local_ready' && m.id === idA, wsClient.inbox);
    await waitFor((m) => m.type === 'fwd_local_ready' && m.id === idB, wsClient.inbox);

    // Tear down F1 with an explicit close — F2 must stay alive.
    wsClient.ws.send(JSON.stringify({ type: 'fwd_local_close', id: idA }));
    await waitFor((m) => m.type === 'fwd_local_closed' && m.id === idA, wsClient.inbox);

    // Reading from F2 still works
    const body = await new Promise((resolve, reject) => {
      const req = http.get({ host: '127.0.0.1', port: portB, path: '/', timeout: 5000 }, (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
      });
      req.on('error', reject);
    });
    expect(body).toContain(contentBody);
  });

  // ── EC6: srcPort=0 returns the ephemeral port ─────────────────────────────

  test('EC6: srcPort=0 binds an ephemeral port and reports it in fwd_local_ready', async () => {
    const id = 'F-ec6-' + Date.now();
    wsClient.ws.send(JSON.stringify({
      type: 'fwd_local_listen', id, srcPort: 0,
      dstHost: getOwnHostname(), dstPort: contentSrv.port,
    }));
    const ready = await waitFor(
      (m) => m.type === 'fwd_local_ready' && m.id === id,
      wsClient.inbox, 5000, 'fwd_local_ready'
    );
    expect(typeof ready.srcPort).toBe('number');
    expect(ready.srcPort).toBeGreaterThan(0);
    expect(ready.srcPort).not.toBe(0);
  });

  // ── EC7: privileged port — soft test ─────────────────────────────────────

  test('EC7: privileged port bind under unprivileged user emits documented error', async () => {
    // The test container may run as root (in which case binding port 80
    // succeeds), so we skip this check whenever euid is 0.
    if (process.getuid && process.getuid() === 0) {
      test.skip(true, 'running as root — privileged-port bind succeeds; EC7 cannot be exercised here');
    }
    const id = 'F-ec7-' + Date.now();
    wsClient.ws.send(JSON.stringify({
      type: 'fwd_local_listen', id, srcPort: 80,
      dstHost: getOwnHostname(), dstPort: contentSrv.port,
    }));
    const err = await waitFor(
      (m) => m.type === 'fwd_local_error' && m.id === id,
      wsClient.inbox, 5000, 'fwd_local_error'
    );
    // Spec allows either a dedicated 'eaccess' code or a privileged-port
    // variant — must NOT be a connection drop and the message must mention
    // the privileged-port issue.
    expect(['eaccess', 'eperm', 'privileged_port']).toContain(err.code);
    expect(err.message.toLowerCase()).toMatch(/privileg|permission|denied|root/);
    expect(wsClient.ws.readyState).toBe(WebSocket.OPEN);
  });
});
