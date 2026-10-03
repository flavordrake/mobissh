/**
 * test/infra/feedback-store-settings.test.js
 *
 * #1257: the bug-report meta object is an ALLOWLIST, so a field the app sends
 * but saveBugReport does not name is dropped on ingest. This pins that the
 * `settings` snapshot (non-secret UI prefs + feature flags) survives into
 * `${ts}-bug-report.json`, and that a report without it still writes (null).
 *
 * #1210: the same allowlist dropped lifecycleLog, controlModeTrace,
 * detectionGeom, termReplyTrace and source. Each is pinned here too.
 */

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const REPO_ROOT = path.resolve(__dirname, '../..');
const store = require(path.join(REPO_ROOT, 'server/feedback-store.js'));

function readMeta(dir) {
  const name = fs.readdirSync(dir).find((f) => f.endsWith('-bug-report.json'));
  assert.ok(name, 'a bug-report meta json was written');
  return JSON.parse(fs.readFileSync(path.join(dir, name), 'utf8'));
}

describe('saveBugReport settings snapshot (#1257)', () => {
  it('persists the settings object verbatim', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fs1257-'));
    store.saveBugReport({
      comment: 'settings please',
      version: '[0.1.13-dev+199 abc]',
      settings: {
        'mobissh.ui.fontSize': 15,
        'mobissh.ui.tmuxControlMode': true,
        'mobissh.ui.featureFlags': { v: 1, showExperimental: false },
      },
    }, dir);
    const meta = readMeta(dir);
    assert.equal(meta.settings['mobissh.ui.fontSize'], 15);
    assert.equal(meta.settings['mobissh.ui.tmuxControlMode'], true);
    assert.deepEqual(meta.settings['mobissh.ui.featureFlags'], { v: 1, showExperimental: false });
  });

  it('writes null settings when the report carries none (or a non-object)', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fs1257-'));
    store.saveBugReport({ comment: 'none', version: '[v]', settings: 'nope' }, dir);
    assert.equal(readMeta(dir).settings, null);
  });
});

describe('saveBugReport keeps the #1210 fields', () => {
  it('persists lifecycleLog, controlModeTrace, detectionGeom and source', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fs1210-'));
    store.saveBugReport({
      comment: 'x',
      version: '[v]',
      source: 'native-in-app',
      lifecycleLog: ['resume probe ok', 'reconnect skipped'],
      controlModeTrace: ['attach %1'],
      detectionGeom: { paintTick: 7, washRows: [1, 2] },
    }, dir);
    const meta = readMeta(dir);
    assert.equal(meta.source, 'native-in-app');
    assert.deepEqual(meta.lifecycleLog, ['resume probe ok', 'reconnect skipped']);
    assert.deepEqual(meta.controlModeTrace, ['attach %1']);
    assert.deepEqual(meta.detectionGeom, { paintTick: 7, washRows: [1, 2] });
  });

  it('persists termReplyTrace as a sidecar with its event count', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fs1210-'));
    store.saveBugReport({
      comment: 'x',
      version: '[v]',
      termReplyTrace: [{ tMs: 1, b64: 'G1s/NjJj', kind: 'da' }],
    }, dir);
    const meta = readMeta(dir);
    assert.equal(meta.termReplyTraceEventCount, 1);
    assert.ok(meta.termReplyTraceFile.endsWith('-bug-report.term-reply-trace.json'));
    const side = JSON.parse(fs.readFileSync(path.join(dir, meta.termReplyTraceFile), 'utf8'));
    assert.equal(side.termReplyTrace[0].kind, 'da');
  });

  it('absent #1210 fields write as empty, not a crash', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fs1210-'));
    store.saveBugReport({ comment: 'x', version: '[v]' }, dir);
    const meta = readMeta(dir);
    assert.equal(meta.source, '');
    assert.deepEqual(meta.lifecycleLog, []);
    assert.deepEqual(meta.controlModeTrace, []);
    assert.equal(meta.detectionGeom, null);
    assert.equal(meta.termReplyTraceFile, '');
    assert.equal(meta.termReplyTraceEventCount, 0);
  });
});
