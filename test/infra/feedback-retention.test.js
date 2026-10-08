/**
 * test/infra/feedback-retention.test.js
 *
 * #1290: test-results/uploads kept everything (6751 files, 1.6 GB) because
 * FEEDBACK_RETENTION_DAYS defaulted to 0. The default is now 90 days; an
 * explicit 0 is the keep-forever opt-out. The feedback service sweeps on boot
 * and daily. Runs against a temp dir only, never the live uploads directory.
 */

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const REPO_ROOT = path.resolve(__dirname, '../..');
const store = require(path.join(REPO_ROOT, 'server/feedback-store.js'));
const SERVICE_SRC = fs.readFileSync(path.join(REPO_ROOT, 'server-feedback/index.js'), 'utf8');

function agedFile(dir, name, days) {
  const p = path.join(dir, name);
  fs.writeFileSync(p, '{}');
  const t = (Date.now() - days * 24 * 60 * 60 * 1000) / 1000;
  fs.utimesSync(p, t, t);
  return p;
}

describe('feedback retention default (#1290)', () => {
  it('is 90 days when FEEDBACK_RETENTION_DAYS is unset or empty', () => {
    assert.equal(store.retentionDays({}), 90);
    assert.equal(store.retentionDays({ FEEDBACK_RETENTION_DAYS: '' }), 90);
  });

  it('an explicit 0 keeps everything; a positive value is honoured', () => {
    assert.equal(store.retentionDays({ FEEDBACK_RETENTION_DAYS: '0' }), 0);
    assert.equal(store.retentionDays({ FEEDBACK_RETENTION_DAYS: '30' }), 30);
  });

  it('a file older than the default window is swept, a newer one kept', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fr1290-'));
    const old = agedFile(dir, 'old-bug-report.json', 100);
    const recent = agedFile(dir, 'recent-bug-report.json', 10);
    assert.equal(store.sweepRetention(dir, store.retentionDays({})), 1);
    assert.ok(!fs.existsSync(old));
    assert.ok(fs.existsSync(recent));
    fs.rmSync(dir, { recursive: true, force: true });
  });

  it('0 disables the sweep', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fr1290-'));
    const old = agedFile(dir, 'old-bug-report.json', 400);
    assert.equal(store.sweepRetention(dir, store.retentionDays({ FEEDBACK_RETENTION_DAYS: '0' })), 0);
    assert.ok(fs.existsSync(old));
    fs.rmSync(dir, { recursive: true, force: true });
  });

  it('the service takes the default from the store and sweeps on boot + daily', () => {
    assert.match(SERVICE_SRC, /store\.retentionDays\(process\.env\)/);
    assert.match(SERVICE_SRC, /store\.sweepRetention\(UPLOADS_DIR, RETENTION_DAYS\);/);
    assert.match(SERVICE_SRC, /setInterval\(\(\) => store\.sweepRetention\(UPLOADS_DIR, RETENTION_DAYS\), 24 \* 60 \* 60 \* 1000\)/);
  });
});
