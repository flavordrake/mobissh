/**
 * test/infra/feedback-store-frame-stats.test.js
 *
 * #1135: the bug-report meta object is an ALLOWLIST — a field the app sends
 * that saveBugReport does not name is silently dropped on ingest. That is the
 * difference between the next stall report carrying frame timing and it
 * arriving, once again, with nothing to read. This pins that `frameStats`
 * survives the round trip into `${ts}-bug-report.json`, and that a report
 * without it still writes cleanly (null, not a crash).
 *
 * Runner is node:test so it needs no node_modules and runs inside agent
 * worktrees; see scripts/test-infra.sh.
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

describe('saveBugReport frame-stats persistence (#1135)', () => {
  it('persists the frameStats section verbatim', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fs1135-'));
    store.saveBugReport({
      title: 'UI is much less responsive',
      comment: 'UI is much less responsive',
      version: '[0.1.12-rc.4+189 abc]',
      frameStats: {
        frames: 4821,
        p50Ms: 9,
        p95Ms: 48,
        maxMs: 1540.5,
        over16: 1200,
        over32: 402,
        over100: 57,
        worst: [
          {
            tsMs: 1790000000000,
            totalMs: 1540.5,
            viewport: { screenH: 874, insetBottom: 280 },
            sessions: { live: 5, connected: 4, streaming: 4 },
          },
        ],
      },
    }, dir);

    const meta = readMeta(dir);
    assert.equal(meta.frameStats.frames, 4821);
    assert.equal(meta.frameStats.p95Ms, 48);
    assert.equal(meta.frameStats.over100, 57);
    assert.equal(meta.frameStats.worst.length, 1);
    assert.equal(meta.frameStats.worst[0].viewport.insetBottom, 280);
    assert.equal(meta.frameStats.worst[0].sessions.streaming, 4);
  });

  it('writes null frameStats when the report carries none', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fs1135-'));
    store.saveBugReport({ comment: 'no frame data', version: '[v]' }, dir);
    const meta = readMeta(dir);
    assert.equal(meta.frameStats, null);
  });
});
