/**
 * tests/capabilities-endpoint.spec.js
 *
 * Red baseline for issue #499 — local Termux bridge slice 1.
 *
 * Covers behavioral assertions:
 *   A1  GET /capabilities returns 200 + JSON + Cache-Control: no-store
 *   A2  Shape is `{ version: 1, bridge: { version, hash }, portForward: { local, remote, dynamic } }`
 *   A3  Default boot: portForward.local === false (protects remote PWA)
 *   A4  Termux mode (env-driven) sets portForward.local === true
 *   A5  Endpoint reachable without WS auth / session cookie
 *   EC1 PWA-side fallback when bridge is older than this PR (covered as the
 *       "missing route" pre-implementation case — pre-implementation the
 *       endpoint 404s, exercising the same path the EC1 PWA must handle)
 *
 * These tests run against the server started by playwright.config.js's
 * `webServer` block (`node server/index.js`). Pre-implementation they FAIL
 * because the route doesn't exist (404 instead of 200). That is the intended
 * red baseline — the develop agent will add the /capabilities route in
 * server/index.js next to /version (around line 843).
 *
 * `tests/version-endpoint.spec.js` is the closest existing model.
 */

const { test, expect } = require('./fixtures.js');

const BASE_URL = (process.env.BASE_URL || 'http://localhost:8081').replace(/\/?$/, '/');

test.describe('Capabilities endpoint (#499)', () => {

  test('A1: /capabilities returns 200 + JSON + Cache-Control: no-store', async ({ request }) => {
    const response = await request.get(BASE_URL + 'capabilities');
    expect(response.status()).toBe(200);
    expect(response.headers()['content-type']).toContain('application/json');
    expect(response.headers()['cache-control']).toBe('no-store');
    // Body parses as JSON
    const data = await response.json();
    expect(typeof data).toBe('object');
    expect(data).not.toBeNull();
  });

  test('A2: shape is { version: 1, bridge: { version, hash }, portForward: { local, remote, dynamic } }', async ({ request }) => {
    const response = await request.get(BASE_URL + 'capabilities');
    expect(response.status()).toBe(200);
    const data = await response.json();

    // Top-level keys: version, bridge, portForward
    expect(data).toHaveProperty('version', 1);
    expect(data).toHaveProperty('bridge');
    expect(data).toHaveProperty('portForward');

    // bridge.version + bridge.hash
    expect(typeof data.bridge).toBe('object');
    expect(typeof data.bridge.version).toBe('string');
    expect(typeof data.bridge.hash).toBe('string');
    expect(data.bridge.version).not.toBe('');
    expect(data.bridge.hash).not.toBe('');

    // portForward booleans, all three keys present
    expect(typeof data.portForward).toBe('object');
    expect(typeof data.portForward.local).toBe('boolean');
    expect(typeof data.portForward.remote).toBe('boolean');
    expect(typeof data.portForward.dynamic).toBe('boolean');
  });

  test('A2b: bridge.version/hash match /version endpoint values', async ({ request }) => {
    // /capabilities.bridge must be derived from the same APP_VERSION / GIT_HASH
    // that /version reports, so the two are never out of sync.
    const verRes = await request.get(BASE_URL + 'version');
    expect(verRes.ok()).toBe(true);
    const ver = await verRes.json();

    const capRes = await request.get(BASE_URL + 'capabilities');
    expect(capRes.status()).toBe(200);
    const cap = await capRes.json();

    expect(cap.bridge.version).toBe(ver.version);
    expect(cap.bridge.hash).toBe(ver.hash);
  });

  test('A3: default boot has portForward.local === false (remote PWA stays unaffected)', async ({ request }) => {
    // No env overrides are applied in the default webServer config. Local
    // forwarding must opt in via an explicit env var. This guards the
    // "do not break mobissh-prod" constraint from the issue.
    const response = await request.get(BASE_URL + 'capabilities');
    expect(response.status()).toBe(200);
    const data = await response.json();
    expect(data.portForward.local).toBe(false);
    expect(data.portForward.remote).toBe(false);
    expect(data.portForward.dynamic).toBe(false);
  });

  test('A4: Termux mode opts in via env var (MOBISSH_LOCAL_FORWARDS=1)', async () => {
    // Spawn a fresh bridge with MOBISSH_LOCAL_FORWARDS=1 on a free port and
    // hit its /capabilities. We can't poke at the test's pre-started server
    // because Playwright's webServer is shared and started with no overrides.
    //
    // This test FAILS pre-implementation: either MOBISSH_LOCAL_FORWARDS is
    // ignored (still local:false) or /capabilities 404s entirely.
    const { spawn } = require('node:child_process');
    const { createServer } = require('node:net');
    const path = require('node:path');

    // Find a free port
    const port = await new Promise((resolve, reject) => {
      const srv = createServer();
      srv.listen(0, () => {
        const { port: p } = srv.address();
        srv.close(() => resolve(p));
      });
      srv.on('error', reject);
    });

    const repoRoot = path.resolve(__dirname, '..');
    const child = spawn('node', ['server/index.js'], {
      cwd: repoRoot,
      env: {
        ...process.env,
        PORT: String(port),
        MOBISSH_LOCAL_FORWARDS: '1',
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    // Capture logs for failure diagnosis
    const logs = [];
    child.stdout.on('data', (d) => logs.push(['stdout', d.toString()]));
    child.stderr.on('data', (d) => logs.push(['stderr', d.toString()]));

    try {
      // Poll until /capabilities responds (or timeout)
      const deadline = Date.now() + 8000;
      let body = null;
      while (Date.now() < deadline) {
        try {
          const res = await fetch(`http://127.0.0.1:${port}/capabilities`);
          if (res.status === 200) {
            body = await res.json();
            break;
          }
        } catch { /* not up yet */ }
        await new Promise((r) => setTimeout(r, 200));
      }

      expect(body, `bridge didn't serve /capabilities. logs: ${JSON.stringify(logs.slice(-10))}`).not.toBeNull();
      expect(body.portForward.local).toBe(true);
      // remote/dynamic stay false in slice 1
      expect(body.portForward.remote).toBe(false);
      expect(body.portForward.dynamic).toBe(false);
    } finally {
      child.kill('SIGTERM');
      // Give it a moment to clean up so the OS releases the port
      await new Promise((r) => setTimeout(r, 200));
    }
  });

  test('A5: endpoint reachable with no WS token, no cookie, no session', async ({ request }) => {
    // Playwright's `request` fixture has no app-issued cookies or WS state.
    // Hitting /capabilities directly must work — it's read on PWA boot
    // before any user gesture.
    const response = await request.get(BASE_URL + 'capabilities', {
      headers: {
        // Explicitly strip cookies; Playwright doesn't send any here anyway,
        // but be defensive in case future fixtures add a Cookie default.
        cookie: '',
      },
    });
    expect(response.status()).toBe(200);
  });

  test('EC1: client can detect "older bridge" via 404 — endpoint must NOT return arbitrary 5xx', async ({ request }) => {
    // When the route IS implemented, this just confirms the canonical 200 path.
    // The EC1 fallback (loadCapabilities returns local:false on 404) is unit-
    // tested in src/modules/__tests__/forwards-capabilities.test.ts. Here we
    // only assert the SERVER side never throws a 500 — a stale bridge must
    // return 404, never a crash response.
    const response = await request.get(BASE_URL + 'capabilities');
    // Either 200 (implemented) or 404 (older bridge). Anything else (500, 502)
    // would crash the PWA boot path because the parser can't distinguish.
    expect([200, 404]).toContain(response.status());
  });
});
