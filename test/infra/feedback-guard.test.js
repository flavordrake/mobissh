/**
 * test/infra/feedback-guard.test.js
 *
 * Unit + integration tests for feedback upload hardening (#484).
 *
 * The feedback ingestion routes (/api/bug-report, /api/native-crash) were
 * unauthenticated and unbounded on BOTH front doors (server/index.js +
 * server-feedback/index.js), sharing server/feedback-store.js. This asserts the
 * shared guard (server/feedback-guard.js):
 *   - encoded body cap (413) BEFORE buffering/decoding the whole thing
 *   - decoded per-image cap (oversized artifact skipped, no giant file written)
 *   - mandatory auth (401 missing/wrong header; 503 when key unconfigured)
 *   - per-client rate limit (429) that a spoofed X-Forwarded-For cannot reset
 *   - a global byte budget across uploads (429) (#1250)
 *   - /api/install-feedback only from the same origin with a JSON body (#1250)
 *   - a valid, in-cap, authenticated request still succeeds and writes (no regression)
 * and that BOTH doors enforce it (server-feedback e2e + server/index.js wiring).
 * The approval bridge routes are gone from the front door (#1261).
 *
 * Relocated from src/modules/__tests__/feedback-guard.test.ts when the PWA was
 * retired (#1205). Runner is node:test so it needs no node_modules and runs
 * inside agent worktrees; see scripts/test-infra.sh.
 */

const { describe, it, before, beforeEach, after } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const REPO_ROOT = path.resolve(__dirname, '../..');

// UPLOADS_DIR + key are read at module-load by server-feedback/index.js and
// per-request by the guard, so set them BEFORE requiring the door.
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'fb484-'));
process.env.UPLOADS_DIR = TMP;
process.env.MOBISSH_FEEDBACK_KEY = 'test-key-484';
process.env.MOBISSH_FEEDBACK_RATE_MAX = '10000'; // generous default; the rate test lowers it

const guard = require(path.join(REPO_ROOT, 'server/feedback-guard.js'));
const service = require(path.join(REPO_ROOT, 'server-feedback/index.js'));

const KEY = 'test-key-484';

function uploadFiles() {
  try { return fs.readdirSync(TMP); } catch { return []; }
}

let port = 0;

before(async () => {
  await new Promise((resolve) => service.server.listen(0, '127.0.0.1', resolve));
  port = service.server.address().port;
});

beforeEach(() => {
  guard.resetRateLimit();
  process.env.MOBISSH_FEEDBACK_KEY = KEY;
  delete process.env.MOBISSH_FEEDBACK_MAX_BYTES;
  delete process.env.MOBISSH_FEEDBACK_IMAGE_MAX_BYTES;
  delete process.env.MOBISSH_FEEDBACK_BUDGET_BYTES;
  process.env.MOBISSH_FEEDBACK_RATE_MAX = '10000';
  // clear the uploads dir between tests
  for (const f of uploadFiles()) { try { fs.unlinkSync(path.join(TMP, f)); } catch { /* ignore */ } }
});

after(() => {
  try { service.server.close(); } catch { /* ignore */ }
  try { fs.rmSync(TMP, { recursive: true, force: true }); } catch { /* ignore */ }
});

function post(urlPath, body, headers = {}) {
  return new Promise((resolve, reject) => {
    const r = http.request(
      { host: '127.0.0.1', port, path: urlPath, method: 'POST', headers: { 'Content-Type': 'application/json', ...headers } },
      (res) => {
        let out = '';
        res.on('data', (c) => { out += c; });
        res.on('end', () => resolve({ status: res.statusCode || 0, body: out }));
      },
    );
    r.on('error', reject);
    r.end(body);
  });
}

const authHdr = { 'X-MobiSSH-Key': KEY };

describe('feedback-guard #484 — shared guard', () => {
  it('rejects an over-cap ENCODED body with 413 and writes nothing', async () => {
    process.env.MOBISSH_FEEDBACK_MAX_BYTES = '1024'; // 1KB cap for the test
    const big = JSON.stringify({ title: 'x', logs: 'A'.repeat(4096) }); // > 1KB
    const res = await post('/api/bug-report', big, authHdr);
    assert.equal(res.status, 413);
    assert.equal(uploadFiles().length, 0);
  });

  it('rejects an oversized DECODED image artifact (small-ish encoded) without writing a giant file', async () => {
    process.env.MOBISSH_FEEDBACK_IMAGE_MAX_BYTES = '64'; // 64-byte per-image decoded cap
    // decoded screenshot is ~300 bytes (> 64) but the encoded body stays under the byte cap
    const shot = 'data:image/png;base64,' + Buffer.alloc(300, 7).toString('base64');
    const res = await post('/api/bug-report', JSON.stringify({ title: 'shot', screenshot: shot }), authHdr);
    assert.equal(res.status, 200);
    // the oversized screenshot must NOT be written; only the meta .json is
    assert.equal(uploadFiles().some((f) => f.endsWith('-bug-report.png')), false);
    assert.equal(uploadFiles().some((f) => f.endsWith('-bug-report.json')), true);
  });

  it('rejects a request with no auth header (401) and writes nothing', async () => {
    const res = await post('/api/bug-report', JSON.stringify({ title: 'x' }), {});
    assert.equal(res.status, 401);
    assert.equal(uploadFiles().length, 0);
  });

  it('rejects a request with a WRONG auth header (401) and writes nothing', async () => {
    const res = await post('/api/bug-report', JSON.stringify({ title: 'x' }), { 'X-MobiSSH-Key': 'nope' });
    assert.equal(res.status, 401);
    assert.equal(uploadFiles().length, 0);
  });

  it('rejects with 503 when the feedback key is not configured (block, do not degrade)', async () => {
    delete process.env.MOBISSH_FEEDBACK_KEY;
    const res = await post('/api/bug-report', JSON.stringify({ title: 'x' }), authHdr);
    assert.equal(res.status, 503);
    assert.equal(uploadFiles().length, 0);
  });

  it('rejects once the per-IP rate limit is exceeded (429)', async () => {
    process.env.MOBISSH_FEEDBACK_RATE_MAX = '2';
    guard.resetRateLimit();
    const a = await post('/api/bug-report', JSON.stringify({ title: 'r' }), authHdr);
    const b = await post('/api/bug-report', JSON.stringify({ title: 'r' }), authHdr);
    const c = await post('/api/bug-report', JSON.stringify({ title: 'r' }), authHdr);
    assert.equal(a.status, 200);
    assert.equal(b.status, 200);
    assert.equal(c.status, 429);
  });

  it('#1250: a spoofed X-Forwarded-For does not reset the rate limit', async () => {
    process.env.MOBISSH_FEEDBACK_RATE_MAX = '2';
    guard.resetRateLimit();
    const statuses = [];
    for (const xff of ['1.1.1.1', '2.2.2.2', '3.3.3.3']) {
      const r = await post('/api/bug-report', JSON.stringify({ title: 'r' }), { ...authHdr, 'X-Forwarded-For': xff });
      statuses.push(r.status);
    }
    assert.deepEqual(statuses, [200, 200, 429]);
  });

  it('#1250: the global byte budget rejects uploads once spent (429) and writes nothing more', async () => {
    const body = JSON.stringify({ title: 'budget', logs: 'B'.repeat(600) });
    process.env.MOBISSH_FEEDBACK_BUDGET_BYTES = String(Buffer.byteLength(body) + 100);
    guard.resetRateLimit();
    const first = await post('/api/bug-report', body, authHdr);
    assert.equal(first.status, 200);
    const written = uploadFiles().length;
    const second = await post('/api/bug-report', body, authHdr);
    assert.equal(second.status, 429);
    assert.match(second.body, /budget/);
    assert.equal(uploadFiles().length, written);
  });

  it('#1261: the retired telemetry routes answer 404', async () => {
    const res = await post('/api/gesture-telemetry', JSON.stringify({ reason: 'r' }), authHdr);
    assert.equal(res.status, 404);
  });

  it('accepts a valid, in-cap, authenticated bug report and writes it (no regression)', async () => {
    const shot = 'data:image/png;base64,' + Buffer.alloc(32, 1).toString('base64');
    const res = await post('/api/bug-report', JSON.stringify({ title: 'real bug', comment: 'it broke', screenshot: shot }), authHdr);
    assert.equal(res.status, 200);
    assert.ok(res.body.includes('"ok":true'));
    assert.equal(uploadFiles().some((f) => f.endsWith('-bug-report.json')), true);
    assert.equal(uploadFiles().some((f) => f.endsWith('-bug-report.png')), true);
  });
});

describe('feedback-guard #484 — guard unit surface', () => {
  const fakeReq = (headers, ip = '9.9.9.9') => ({ headers, socket: { remoteAddress: ip } });

  it('checkAuth returns null for a matching key, 401 for mismatch, 503 when unset', () => {
    process.env.MOBISSH_FEEDBACK_KEY = KEY;
    assert.equal(guard.checkAuth(fakeReq({ 'x-mobissh-key': KEY })), null);
    assert.equal(guard.checkAuth(fakeReq({ 'x-mobissh-key': 'bad' })).status, 401);
    assert.equal(guard.checkAuth(fakeReq({})).status, 401);
    delete process.env.MOBISSH_FEEDBACK_KEY;
    assert.equal(guard.checkAuth(fakeReq({ 'x-mobissh-key': KEY })).status, 503);
  });

  it('preflight enforces auth before rate limiting', () => {
    process.env.MOBISSH_FEEDBACK_KEY = KEY;
    guard.resetRateLimit();
    assert.equal(guard.preflight(fakeReq({ 'x-mobissh-key': KEY })), null);
    assert.equal(guard.preflight(fakeReq({ 'x-mobissh-key': 'bad' })).status, 401);
  });

  it('#1250: clientKey ignores X-Forwarded-For and trusts the tailnet login only from loopback', () => {
    assert.equal(guard.clientKey(fakeReq({ 'x-forwarded-for': '6.6.6.6' }, '10.0.0.5')), '10.0.0.5');
    assert.equal(guard.clientKey(fakeReq({ 'tailscale-user-login': 'a@b' }, '127.0.0.1')), 'ts:a@b');
    // A docker-network peer cannot pick its own key by forging the header.
    assert.equal(guard.clientKey(fakeReq({ 'tailscale-user-login': 'a@b' }, '172.18.0.9')), '172.18.0.9');
  });

  it('#1250: checkSameOriginJson wants a JSON body and same-origin proof', () => {
    const json = { 'content-type': 'application/json', host: 'mobissh.example' };
    assert.equal(guard.checkSameOriginJson(fakeReq({ ...json, 'sec-fetch-site': 'same-origin' })), null);
    assert.equal(guard.checkSameOriginJson(fakeReq({ ...json, origin: 'https://mobissh.example' })), null);
    assert.equal(guard.checkSameOriginJson(fakeReq({ ...json, 'x-forwarded-host': 'ts.example', origin: 'https://ts.example' })), null);
    assert.equal(guard.checkSameOriginJson(fakeReq({ ...json, 'content-type': 'text/plain', 'sec-fetch-site': 'same-origin' })).status, 415);
    assert.equal(guard.checkSameOriginJson(fakeReq({ ...json, 'sec-fetch-site': 'cross-site' })).status, 403);
    assert.equal(guard.checkSameOriginJson(fakeReq({ ...json, origin: 'https://evil.example' })).status, 403);
    assert.equal(guard.checkSameOriginJson(fakeReq(json)).status, 403);
  });
});

describe('#1243 — every uploader authenticates', () => {
  it('/api/native-crash accepts the key and rejects a missing or wrong one', async () => {
    const crash = JSON.stringify({ schema: 1, kind: 'dart', error: 'boom' });
    assert.equal((await post('/api/native-crash', crash, {})).status, 401);
    assert.equal((await post('/api/native-crash', crash, { 'X-MobiSSH-Key': 'nope' })).status, 401);
    assert.equal(uploadFiles().length, 0);
    const ok = await post('/api/native-crash', crash, authHdr);
    assert.equal(ok.status, 200);
    assert.equal(uploadFiles().some((f) => f.endsWith('-native-crash.json')), true);
  });

  it('the install-page form posts to the same-origin route and carries no key', () => {
    const src = fs.readFileSync(path.join(REPO_ROOT, 'public/native-feedback.js'), 'utf8');
    assert.match(src, /fetch\('\.\/api\/install-feedback'/);
    assert.doesNotMatch(src, /X-MobiSSH-Key/i);
  });

  describe('server/index.js /api/install-feedback adds the server key', () => {
    let front;
    let frontPort = 0;
    const frontPost = (urlPath, body, headers = {}) => new Promise((resolve, reject) => {
      const r = http.request(
        { host: '127.0.0.1', port: frontPort, path: urlPath, method: 'POST', headers: { 'Content-Type': 'application/json', ...headers } },
        (res) => {
          let out = '';
          res.on('data', (c) => { out += c; });
          res.on('end', () => resolve({ status: res.statusCode || 0, body: out }));
        },
      );
      r.on('error', reject);
      r.end(body);
    });

    before(async () => {
      // Relay to the test feedback service so nothing is written into the repo.
      process.env.FEEDBACK_SERVICE_URL = `http://127.0.0.1:${port}`;
      front = require(path.join(REPO_ROOT, 'server/index.js')).server;
      await new Promise((resolve) => front.listen(0, '127.0.0.1', resolve));
      frontPort = front.address().port;
    });

    after(() => {
      delete process.env.FEEDBACK_SERVICE_URL;
      try { front.close(); } catch { /* ignore */ }
    });

    // What the install page's fetch() sends from a modern browser.
    const samePage = { 'Sec-Fetch-Site': 'same-origin' };

    it('accepts a keyless install-page report and stores it as a bug report', async () => {
      const res = await frontPost('/api/install-feedback', JSON.stringify({ title: 'from install page' }), samePage);
      assert.equal(res.status, 200);
      assert.equal(uploadFiles().some((f) => f.endsWith('-bug-report.json')), true);
    });

    it('install-feedback still blocks (503) when the server has no key', async () => {
      delete process.env.MOBISSH_FEEDBACK_KEY;
      const res = await frontPost('/api/install-feedback', JSON.stringify({ title: 'x' }), samePage);
      assert.equal(res.status, 503);
      assert.equal(uploadFiles().length, 0);
    });

    it('#1250: a cross-site text/plain POST to install-feedback is rejected and writes nothing', async () => {
      const res = await frontPost('/api/install-feedback', JSON.stringify({ title: 'planted' }), {
        'Content-Type': 'text/plain',
        'Sec-Fetch-Site': 'cross-site',
        Origin: 'https://evil.example',
      });
      assert.equal(res.status, 415);
      assert.equal(uploadFiles().length, 0);
    });

    it('#1250: a cross-origin JSON POST to install-feedback is rejected (403)', async () => {
      const crossSite = await frontPost('/api/install-feedback', JSON.stringify({ title: 'x' }), { 'Sec-Fetch-Site': 'cross-site' });
      assert.equal(crossSite.status, 403);
      const foreignOrigin = await frontPost('/api/install-feedback', JSON.stringify({ title: 'x' }), { Origin: 'https://evil.example' });
      assert.equal(foreignOrigin.status, 403);
      const noProof = await frontPost('/api/install-feedback', JSON.stringify({ title: 'x' }));
      assert.equal(noProof.status, 403);
      assert.equal(uploadFiles().length, 0);
    });

    it('#1250: install-feedback accepts an Origin matching the Host when Sec-Fetch-Site is absent', async () => {
      const res = await frontPost('/api/install-feedback', JSON.stringify({ title: 'old browser' }), { Origin: `http://127.0.0.1:${frontPort}` });
      assert.equal(res.status, 200);
    });

    it('#1250: an oversize install-feedback body gets 413', async () => {
      process.env.MOBISSH_FEEDBACK_MAX_BYTES = '1024';
      const res = await frontPost('/api/install-feedback', JSON.stringify({ title: 'x', logs: 'A'.repeat(4096) }), samePage);
      assert.equal(res.status, 413);
      assert.equal(uploadFiles().length, 0);
    });

    it('the keyed routes on the front door still reject a keyless post (401)', async () => {
      const res = await frontPost('/api/bug-report', JSON.stringify({ title: 'x' }));
      assert.equal(res.status, 401);
      assert.equal(uploadFiles().length, 0);
    });

    it('#1261: the approval bridge routes are gone from the front door (404)', async () => {
      for (const route of ['/api/approval-gate?hookVersion=2', '/api/approval-respond', '/api/approval-mode', '/api/hook', '/api/approval']) {
        const res = await frontPost(route, JSON.stringify({ tool_name: 'Bash', mode: 'allow', requestId: '1', decision: 'allow' }));
        assert.equal(res.status, 404, route);
      }
      const events = await new Promise((resolve, reject) => {
        http.get({ host: '127.0.0.1', port: frontPort, path: '/events' }, (res) => {
          res.resume();
          resolve(res.statusCode);
        }).on('error', reject);
      });
      assert.equal(events, 404);
    });
  });
});

describe('feedback-guard #484 — both front doors wire the guard', () => {
  it('server/index.js requires and calls the shared guard preflight', () => {
    const src = fs.readFileSync(path.join(REPO_ROOT, 'server/index.js'), 'utf8');
    assert.ok(src.includes("require('./feedback-guard')"));
    assert.match(src, /feedbackGuard\.preflight\(/);
  });

  it('server-feedback/index.js requires and calls the shared guard preflight', () => {
    const src = fs.readFileSync(path.join(REPO_ROOT, 'server-feedback/index.js'), 'utf8');
    assert.match(src, /require\('\.\.\/server\/feedback-guard'\)/);
    assert.match(src, /guard\.preflight\(/);
  });

  it('server/index.js forwards the auth key when relaying to the feedback service', () => {
    // Otherwise the downstream service (same shared guard) 401s the relayed,
    // already-authenticated request. Prod + service share MOBISSH_FEEDBACK_KEY.
    const src = fs.readFileSync(path.join(REPO_ROOT, 'server/index.js'), 'utf8');
    assert.match(src, /proxyFeedbackBody\([^)]*x-mobissh-key/);
    assert.match(src, /headers\['X-MobiSSH-Key'\] = authKey/);
  });
});
