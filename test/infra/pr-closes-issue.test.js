/**
 * test/infra/pr-closes-issue.test.js
 *
 * `gh-ops.sh integrate PR ISSUE` used to close ISSUE unconditionally, so a PR
 * that only said "Refs #N" closed an umbrella still in progress (#1135, #1259,
 * #1277). It now closes only when the PR body uses a GitHub closing keyword for
 * that exact issue — the decision lives in scripts/lib/pr-closes.sh.
 */

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const { resolve } = require('node:path');

const LIB = resolve(__dirname, '../../scripts/lib/pr-closes.sh');

function closes(body, issue) {
  const r = spawnSync(
    'bash',
    ['-c', `source "${LIB}"; pr_closes_issue "$1" "$2"`, 'x', body, String(issue)],
    { encoding: 'utf-8' },
  );
  return r.status === 0;
}

describe('pr_closes_issue', () => {
  it('closes on a closing keyword for that exact issue', () => {
    for (const kw of ['Closes', 'closes', 'Fixes', 'fixed', 'Resolves', 'close']) {
      assert.ok(closes(`Some text.\n${kw} #1277\n`, 1277), kw);
    }
  });

  it('does NOT close on Refs / a mention / another issue', () => {
    assert.ok(!closes('Refs #1277', 1277));
    assert.ok(!closes('Part of #1277; see #1251', 1277));
    assert.ok(!closes('Closes #12770', 1277), 'prefix of a longer number');
    assert.ok(!closes('Closes #127', 1277));
    assert.ok(!closes('', 1277));
  });

  it('never closes issue 0 (no linked issue)', () => {
    assert.ok(!closes('Closes #0', 0));
  });
});
