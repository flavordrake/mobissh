/**
 * test/infra/bot-branch-trailers.test.js
 *
 * bot-branch.sh hard-coded "Co-Authored-By: Claude Opus 4.6" in both of its
 * commit paths, so every agent commit through it carried a stale model name, and
 * agents bypassed the script to commit by hand (2026-10-05). Attribution changes
 * per session; the caller supplies it through BOT_COMMIT_TRAILERS.
 */

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');

const SRC = readFileSync(resolve(__dirname, '../../scripts/bot-branch.sh'), 'utf-8');

describe('bot-branch.sh commit attribution', () => {
  it('hard-codes no model name or co-author trailer', () => {
    assert.doesNotMatch(SRC, /Co-Authored-By: Claude/);
  });

  it('takes the trailers from BOT_COMMIT_TRAILERS in both commit paths', () => {
    const uses = SRC.match(/BOT_COMMIT_TRAILERS/g) || [];
    assert.ok(uses.length >= 1, 'reads BOT_COMMIT_TRAILERS');
    const commits = SRC.match(/git commit -m "\$\(_commit_message/g) || [];
    assert.equal(commits.length, 2, 'both _commit and _rescue build the message through _commit_message');
  });
});
