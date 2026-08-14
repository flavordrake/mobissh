/**
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
 */
import { describe, it, expect, beforeEach, afterAll } from 'vitest';
import { createRequire } from 'node:module';
import * as http from 'node:http';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';

const req = createRequire(import.meta.url);

// UPLOADS_DIR + key are read at module-load by server-feedback/index.js and
// per-request by the guard, so set them BEFORE requiring the door.
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'fb484-'));
process.env.UPLOADS_DIR = TMP;
process.env.MOBISSH_FEEDBACK_KEY = 'test-key-484';
process.env.MOBISSH_FEEDBACK_RATE_MAX = '10000'; // generous default; the rate test lowers it

const guard = req('../../../server/feedback-guard.js') as {
  maxFeedbackBytes: () => number;
  checkAuth: (r: unknown) => null | { status: number; body: string };
  checkRateLimit: (ip: string) => null | { status: number; body: string };
  preflight: (r: unknown) => null | { status: number; body: string };
  getIP: (r: unknown) => string;
  resetRateLimit: () => void;
};
const service = req('../../../server-feedback/index.js') as { server: http.Server };

const KEY = 'test-key-484';

function uploadFiles(): string[] {
  try { return fs.readdirSync(TMP); } catch { return []; }
}

let port = 0;
beforeEach(async () => {
  guard.resetRateLimit();
  process.env.MOBISSH_FEEDBACK_KEY = KEY;
  delete process.env.MOBISSH_FEEDBACK_MAX_BYTES;
  delete process.env.MOBISSH_FEEDBACK_IMAGE_MAX_BYTES;
  process.env.MOBISSH_FEEDBACK_RATE_MAX = '10000';
  // clear the uploads dir between tests
  for (const f of uploadFiles()) { try { fs.unlinkSync(path.join(TMP, f)); } catch { /* ignore */ } }
  if (!port) {
    await new Promise<void>((resolve) => service.server.listen(0, '127.0.0.1', resolve));
    port = (service.server.address() as { port: number }).port;
  }
});

afterAll(() => {
  try { service.server.close(); } catch { /* ignore */ }
});

interface Resp { status: number; body: string }
function post(urlPath: string, body: string, headers: Record<string, string> = {}): Promise<Resp> {
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
    expect(res.status).toBe(413);
    expect(uploadFiles().length).toBe(0);
  });

  it('rejects an oversized DECODED image artifact (small-ish encoded) without writing a giant file', async () => {
    process.env.MOBISSH_FEEDBACK_IMAGE_MAX_BYTES = '64'; // 64-byte per-image decoded cap
    // decoded screenshot is ~300 bytes (> 64) but the encoded body stays under the byte cap
    const shot = 'data:image/png;base64,' + Buffer.alloc(300, 7).toString('base64');
    const res = await post('/api/bug-report', JSON.stringify({ title: 'shot', screenshot: shot }), authHdr);
    expect(res.status).toBe(200);
    // the oversized screenshot must NOT be written; only the meta .json is
    expect(uploadFiles().some((f) => f.endsWith('-bug-report.png'))).toBe(false);
    expect(uploadFiles().some((f) => f.endsWith('-bug-report.json'))).toBe(true);
  });

  it('rejects a request with no auth header (401) and writes nothing', async () => {
    const res = await post('/api/bug-report', JSON.stringify({ title: 'x' }), {});
    expect(res.status).toBe(401);
    expect(uploadFiles().length).toBe(0);
  });

  it('rejects a request with a WRONG auth header (401) and writes nothing', async () => {
    const res = await post('/api/bug-report', JSON.stringify({ title: 'x' }), { 'X-MobiSSH-Key': 'nope' });
    expect(res.status).toBe(401);
    expect(uploadFiles().length).toBe(0);
  });

  it('rejects with 503 when the feedback key is not configured (block, do not degrade)', async () => {
    delete process.env.MOBISSH_FEEDBACK_KEY;
    const res = await post('/api/bug-report', JSON.stringify({ title: 'x' }), authHdr);
    expect(res.status).toBe(503);
    expect(uploadFiles().length).toBe(0);
  });

  it('rejects once the per-IP rate limit is exceeded (429)', async () => {
    process.env.MOBISSH_FEEDBACK_RATE_MAX = '2';
    guard.resetRateLimit();
    const a = await post('/api/gesture-telemetry', JSON.stringify({ reason: 'r' }), authHdr);
    const b = await post('/api/gesture-telemetry', JSON.stringify({ reason: 'r' }), authHdr);
    const c = await post('/api/gesture-telemetry', JSON.stringify({ reason: 'r' }), authHdr);
    expect(a.status).toBe(200);
    expect(b.status).toBe(200);
    expect(c.status).toBe(429);
  });

  it('accepts a valid, in-cap, authenticated bug report and writes it (no regression)', async () => {
    const shot = 'data:image/png;base64,' + Buffer.alloc(32, 1).toString('base64');
    const res = await post('/api/bug-report', JSON.stringify({ title: 'real bug', comment: 'it broke', screenshot: shot }), authHdr);
    expect(res.status).toBe(200);
    expect(res.body).toContain('"ok":true');
    expect(uploadFiles().some((f) => f.endsWith('-bug-report.json'))).toBe(true);
    expect(uploadFiles().some((f) => f.endsWith('-bug-report.png'))).toBe(true);
  });
});

describe('feedback-guard #484 — guard unit surface', () => {
  const fakeReq = (headers: Record<string, string>, ip = '9.9.9.9') => ({ headers, socket: { remoteAddress: ip } });

  it('checkAuth returns null for a matching key, 401 for mismatch, 503 when unset', () => {
    process.env.MOBISSH_FEEDBACK_KEY = KEY;
    expect(guard.checkAuth(fakeReq({ 'x-mobissh-key': KEY }))).toBeNull();
    expect(guard.checkAuth(fakeReq({ 'x-mobissh-key': 'bad' }))?.status).toBe(401);
    expect(guard.checkAuth(fakeReq({}))?.status).toBe(401);
    delete process.env.MOBISSH_FEEDBACK_KEY;
    expect(guard.checkAuth(fakeReq({ 'x-mobissh-key': KEY }))?.status).toBe(503);
  });

  it('preflight enforces auth before rate limiting', () => {
    process.env.MOBISSH_FEEDBACK_KEY = KEY;
    guard.resetRateLimit();
    expect(guard.preflight(fakeReq({ 'x-mobissh-key': KEY }))).toBeNull();
    expect(guard.preflight(fakeReq({ 'x-mobissh-key': 'bad' }))?.status).toBe(401);
  });
});

describe('feedback-guard #484 — both front doors wire the guard', () => {
  it('server/index.js requires and calls the shared guard preflight', () => {
    const src = fs.readFileSync(path.join(__dirname, '../../../server/index.js'), 'utf8');
    expect(src).toContain("require('./feedback-guard')");
    expect(src).toMatch(/feedbackGuard\.preflight\(/);
  });

  it('server-feedback/index.js requires and calls the shared guard preflight', () => {
    const src = fs.readFileSync(path.join(__dirname, '../../../server-feedback/index.js'), 'utf8');
    expect(src).toMatch(/require\('\.\.\/server\/feedback-guard'\)/);
    expect(src).toMatch(/guard\.preflight\(/);
  });

  it('server/index.js forwards the auth key when relaying to the feedback service', () => {
    // Otherwise the downstream service (same shared guard) 401s the relayed,
    // already-authenticated request. Prod + service share MOBISSH_FEEDBACK_KEY.
    const src = fs.readFileSync(path.join(__dirname, '../../../server/index.js'), 'utf8');
    expect(src).toMatch(/proxyFeedbackBody\([^)]*x-mobissh-key/);
    expect(src).toMatch(/headers\['X-MobiSSH-Key'\] = authKey/);
  });
});
