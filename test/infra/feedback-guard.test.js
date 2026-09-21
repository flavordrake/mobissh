/**
 * test/infra/feedback-guard.test.js
 *
 * Unit + integration tests for feedback upload hardening (#484).
 *
 * The four feedback ingestion routes (/api/bug-report, /api/drop-telemetry,
 * /api/gesture-telemetry, /api/native-crash) were unauthenticated and unbounded
 * on BOTH front doors (server/index.js + server-feedback/index.js), sharing
 * server/feedback-store.js. This asserts the shared guard (server/feedback-guard.js):
 *   - encoded body cap (413) BEFORE buffering/decoding the whole thing
 *   - decoded per-image cap (oversized artifact skipped, no giant file written)
 *   - mandatory auth (401 missing/wrong header; 503 when key unconfigured)
 *   - per-IP rate limit (429)
 *   - a valid, in-cap, authenticated request still succeeds and writes (no regression)
 * and that BOTH doors enforce it (server-feedback e2e + server/index.js wiring).
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
    const a = await post('/api/gesture-telemetry', JSON.stringify({ reason: 'r' }), authHdr);
    const b = await post('/api/gesture-telemetry', JSON.stringify({ reason: 'r' }), authHdr);
    const c = await post('/api/gesture-telemetry', JSON.stringify({ reason: 'r' }), authHdr);
    assert.equal(a.status, 200);
    assert.equal(b.status, 200);
    assert.equal(c.status, 429);
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
