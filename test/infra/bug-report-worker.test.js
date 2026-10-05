/**
 * test/infra/bug-report-worker.test.js
 *
 * The public Cloudflare bug-report Worker (infra/bug-report-worker/worker.js):
 *   - #1250: per-IP ingest rate limit (the writer key ships in the public APK)
 *   - #1250: a body without Content-Length is capped while streaming (413)
 *   - #1274: the privacy page states the real retention, matching docs/PRIVACY.md
 *
 * worker.js is an ES module with no package.json beside it, so it is copied to
 * a temp .mjs and imported. Node 20 provides Request/Response/ReadableStream,
 * crypto.randomUUID and atob, the Workers globals it uses.
 */

const { describe, it, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { pathToFileURL } = require('node:url');

const REPO_ROOT = path.resolve(__dirname, '../..');
const WORKER_SRC = path.join(REPO_ROOT, 'infra/bug-report-worker/worker.js');
const KEY = 'worker-test-key';

let worker;
let tmpDir;
const stored = [];
const env = {
  FEEDBACK_KEY: KEY,
  REPORTS: { put: async (key, body) => { stored.push({ key, body }); } },
};

before(async () => {
  tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'bug-report-worker-'));
  const copy = path.join(tmpDir, 'worker.mjs');
  fs.copyFileSync(WORKER_SRC, copy);
  worker = (await import(pathToFileURL(copy).href)).default;
});

after(() => {
  fs.rmSync(tmpDir, { recursive: true, force: true });
});

function ingest(ip, body, extraHeaders = {}) {
  return worker.fetch(new Request('https://w.example/', {
    method: 'POST',
    headers: { 'X-MobiSSH-Key': KEY, 'CF-Connecting-IP': ip, 'Content-Type': 'application/json', ...extraHeaders },
    body,
  }), env);
}

describe('bug-report Worker ingest (#1250)', () => {
  it('rate-limits one IP after 10 reports a minute without blocking other IPs', async () => {
    const statuses = [];
    for (let i = 0; i < 11; i++) statuses.push((await ingest('203.0.113.7', '{"title":"x"}')).status);
    assert.deepEqual(statuses.slice(0, 10), Array(10).fill(200));
    assert.equal(statuses[10], 429);
    assert.equal((await ingest('203.0.113.8', '{"title":"x"}')).status, 200);
  });

  it('rejects a streamed body over 25 MB with 413 and stores nothing', async () => {
    const before = stored.length;
    const chunk = new Uint8Array(1024 * 1024).fill(0x41);
    let sent = 0;
    const stream = new ReadableStream({
      pull(controller) {
        if (sent++ < 26) controller.enqueue(chunk); else controller.close();
      },
    });
    const res = await worker.fetch(new Request('https://w.example/', {
      method: 'POST',
      headers: { 'X-MobiSSH-Key': KEY, 'CF-Connecting-IP': '203.0.113.9' },
      body: stream,
      duplex: 'half',
    }), env);
    assert.equal(res.status, 413);
    assert.equal(stored.length, before);
  });

  it('still rejects a missing key with 403', async () => {
    const res = await worker.fetch(new Request('https://w.example/', { method: 'POST', body: '{}' }), env);
    assert.equal(res.status, 403);
  });
});

describe('bug-report Worker privacy page (#1274)', () => {
  it('does not promise 30-day deletion and states the real retention', async () => {
    const res = await worker.fetch(new Request('https://w.example/privacy'), env);
    assert.equal(res.status, 200);
    const page = await res.text();
    assert.doesNotMatch(page, /30 days/);
    assert.match(page, /no automatic deletion/);
    const privacyMd = fs.readFileSync(path.join(REPO_ROOT, 'docs/PRIVACY.md'), 'utf8');
    assert.match(privacyMd, /no automatic deletion/);
  });
});
