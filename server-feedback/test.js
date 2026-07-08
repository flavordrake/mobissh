'use strict';

/**
 * server-feedback/test.js — round-trip tests for the feedback service (#997)
 *
 * Run with: npm test  (from the server-feedback/ directory)
 *
 * Uploads land in a temp dir (UPLOADS_DIR is read at require time, so it is
 * set before the service module loads). Asserts the exact filename contract
 * the dev-loop consumers (watch-bug-reports.sh, assemble-repro.sh, the replay
 * harness) depend on.
 */

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');

const TMP_UPLOADS = fs.mkdtempSync(path.join(os.tmpdir(), 'mobissh-feedback-test-'));
process.env.UPLOADS_DIR = TMP_UPLOADS;

const { server } = require('./index.js');
const store = require('../server/feedback-store.js');

let baseUrl = '';

before(async () => {
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});

after(async () => {
  await new Promise((resolve) => server.close(resolve));
  fs.rmSync(TMP_UPLOADS, { recursive: true, force: true });
});

function post(route, body, headers) {
  return new Promise((resolve, reject) => {
    const req = http.request(baseUrl + route, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...(headers || {}) },
    }, (res) => {
      let out = '';
      res.on('data', (c) => { out += c; });
      res.on('end', () => resolve({ status: res.statusCode, body: out }));
    });
    req.on('error', reject);
    req.end(body);
  });
}

function get(route) {
  return new Promise((resolve, reject) => {
    http.get(baseUrl + route, (res) => {
      let out = '';
      res.on('data', (c) => { out += c; });
      res.on('end', () => resolve({ status: res.statusCode, body: out }));
    }).on('error', reject);
  });
}

function uploadsWith(suffix) {
  return fs.readdirSync(TMP_UPLOADS).filter((n) => n.endsWith(suffix));
}

// 1x1 transparent PNG as a data URL
const PNG_DATA_URL = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

test('healthz reports service identity and uploads dir', async () => {
  const res = await get('/healthz');
  assert.equal(res.status, 200);
  const j = JSON.parse(res.body);
  assert.equal(j.ok, true);
  assert.equal(j.service, 'mobissh-feedback');
  assert.equal(j.uploadsDir, TMP_UPLOADS);
});

test('bug-report round-trip writes the full sidecar set', async () => {
  const payload = {
    title: '[1.0 abc123] terminal froze',
    comment: 'terminal froze\nafter switching tmux windows\nline three',
    logs: 'terminal froze\nafter switching tmux windows\nline three',
    userAgent: 'test-agent',
    url: 'https://mobissh.example/app',
    version: '[1.0 abc123]',
    screenshot: PNG_DATA_URL,
    frames: [PNG_DATA_URL, PNG_DATA_URL],
    connectLog: [{ t: 1, ev: 'connect' }],
    gestureLog: [{ t: 2, ev: 'swipe' }],
    byteTrace: [{ tMs: 1, b64: 'aGk=' }],
    scrollTrace: [{ tMs: 2, offset: 3 }],
    sentSgrTrace: [{ tMs: 3, b64: 'c2dy' }],
    grid: { cols: 80, rows: 24 },
  };
  const res = await post('/api/bug-report', JSON.stringify(payload));
  assert.equal(res.status, 200);
  assert.deepEqual(JSON.parse(res.body), { ok: true, saved: true });

  const metaName = uploadsWith('-bug-report.json')[0];
  assert.ok(metaName, 'meta json written');
  const ts = metaName.replace('-bug-report.json', '');
  const meta = JSON.parse(fs.readFileSync(path.join(TMP_UPLOADS, metaName), 'utf8'));
  assert.equal(meta.comment, payload.comment);
  assert.equal(meta.title, payload.title);
  assert.equal(meta.frameCount, 2);
  assert.equal(meta.framesPattern, `${ts}-bug-report.frame-%03d.png`);
  assert.deepEqual(meta.grid, { cols: 80, rows: 24 });

  // Exact filename contract the dev-loop scripts glob for.
  for (const f of [
    `${ts}-bug-report.png`,
    `${ts}-bug-report.log`,
    `${ts}-bug-report.frame-001.png`,
    `${ts}-bug-report.frame-002.png`,
    `${ts}-bug-report.connect-log.json`,
    `${ts}-bug-report.gesture-log.json`,
    `${ts}-bug-report.byte-trace.json`,
    `${ts}-bug-report.sent-sgr-trace.json`,
  ]) {
    assert.ok(fs.existsSync(path.join(TMP_UPLOADS, f)), `${f} written`);
  }

  // Byte-trace sidecar shape consumed by the replay harness (#790).
  const bt = JSON.parse(fs.readFileSync(path.join(TMP_UPLOADS, `${ts}-bug-report.byte-trace.json`), 'utf8'));
  assert.deepEqual(bt.grid, { cols: 80, rows: 24 });
  assert.equal(bt.byteTrace.length, 1);
  assert.equal(bt.scrollTrace.length, 1);
});

test('bug-report rejects invalid json with 400', async () => {
  const res = await post('/api/bug-report', 'not json {');
  assert.equal(res.status, 400);
  assert.deepEqual(JSON.parse(res.body), { error: 'invalid json' });
});

test('drop-telemetry round-trip', async () => {
  const res = await post('/api/drop-telemetry', JSON.stringify({
    kind: 'drop-recovery',
    reason: 'ws-close',
    host: 'fd-dev',
    connectLog: [{ t: 1, ev: 'reconnect' }],
  }));
  assert.equal(res.status, 200);
  const j = JSON.parse(res.body);
  assert.equal(j.ok, true);
  assert.ok(j.stamp);
  const meta = JSON.parse(fs.readFileSync(path.join(TMP_UPLOADS, `${j.stamp}-drop-telemetry.json`), 'utf8'));
  assert.equal(meta.reason, 'ws-close');
  assert.equal(meta.host, 'fd-dev');
  assert.ok(fs.existsSync(path.join(TMP_UPLOADS, `${j.stamp}-drop-telemetry.connect-log.json`)));
});

test('gesture-telemetry round-trip', async () => {
  const res = await post('/api/gesture-telemetry', JSON.stringify({
    reason: 'ime-anomaly',
    eventCount: 2,
    log: [{ t: 1 }, { t: 2 }],
  }));
  assert.equal(res.status, 200);
  const j = JSON.parse(res.body);
  const meta = JSON.parse(fs.readFileSync(path.join(TMP_UPLOADS, `${j.stamp}-gesture-telemetry.json`), 'utf8'));
  assert.equal(meta.reason, 'ime-anomaly');
  assert.equal(meta.logEventCount, 2);
  assert.ok(fs.existsSync(path.join(TMP_UPLOADS, `${j.stamp}-gesture-telemetry.gesture-log.json`)));
});

test('native-crash JSON body persists as .json', async () => {
  const res = await post('/api/native-crash', JSON.stringify({ kind: 'dart', error: 'boom' }));
  assert.equal(res.status, 200);
  const j = JSON.parse(res.body);
  assert.equal(j.ok, true);
  assert.match(j.path, /-native-crash\.json$/);
  const saved = JSON.parse(fs.readFileSync(path.join(TMP_UPLOADS, j.path), 'utf8'));
  assert.equal(saved.error, 'boom');
});

test('native-crash non-JSON body preserved as .raw', async () => {
  const res = await post('/api/native-crash', 'FATAL EXCEPTION: main\n  at ...');
  assert.equal(res.status, 200);
  const j = JSON.parse(res.body);
  assert.equal(j.raw, true);
  assert.match(j.path, /-native-crash\.raw$/);
  assert.ok(fs.existsSync(path.join(TMP_UPLOADS, j.path)));
});

test('native-crash over 1MB answers 413', async () => {
  const big = JSON.stringify({ kind: 'dart', error: 'x'.repeat(1024 * 1024 + 64) });
  const res = await post('/api/native-crash', big).catch((err) => ({ status: 413, aborted: true, err }));
  // The server destroys the request after responding; depending on timing the
  // client sees the 413 or a socket reset. Either way nothing was persisted.
  if (!res.aborted) assert.equal(res.status, 413);
  const before413 = uploadsWith('-native-crash.json').length + uploadsWith('-native-crash.raw').length;
  assert.equal(before413, 2); // only the two crash files from the tests above
});

test('unknown route answers 404', async () => {
  const res = await post('/api/nope', '{}');
  assert.equal(res.status, 404);
});

test('retention sweep deletes only files older than the knob', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mobissh-retention-test-'));
  const oldFile = path.join(dir, 'old-bug-report.json');
  const newFile = path.join(dir, 'new-bug-report.json');
  fs.writeFileSync(oldFile, '{}');
  fs.writeFileSync(newFile, '{}');
  const tenDaysAgo = (Date.now() - 10 * 24 * 60 * 60 * 1000) / 1000;
  fs.utimesSync(oldFile, tenDaysAgo, tenDaysAgo);

  // Default (0) keeps everything.
  assert.equal(store.sweepRetention(dir, 0), 0);
  assert.ok(fs.existsSync(oldFile));

  // 7-day knob deletes only the old file.
  assert.equal(store.sweepRetention(dir, 7), 1);
  assert.ok(!fs.existsSync(oldFile));
  assert.ok(fs.existsSync(newFile));
  fs.rmSync(dir, { recursive: true, force: true });
});
