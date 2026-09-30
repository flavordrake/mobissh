/**
 * test/infra/bot-branch-worktree.test.js
 *
 * scripts/bot-branch.sh called from a develop agent's OWN worktree must work in
 * that worktree and never touch the main checkout (#1224). It used to cd into
 * the main repo and `git checkout -B bot/issue-N` there, then trap back to
 * main on exit — the exact main-checkout hijack agents.md forbids (#537).
 *
 * Builds a throwaway repo (bare origin + main checkout + a worktree under
 * .claude/worktrees/) holding copies of the real scripts, so REPO_ROOT resolves
 * inside the sandbox and nothing reaches the real repo.
 */

const { describe, it, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync, spawnSync } = require('node:child_process');
const { mkdtempSync, mkdirSync, copyFileSync, rmSync, writeFileSync } = require('node:fs');
const { resolve, join } = require('node:path');
const { tmpdir } = require('node:os');

const REPO_ROOT = resolve(__dirname, '../..');

function git(cwd, ...args) {
  return execFileSync('git', args, { cwd, encoding: 'utf-8' }).trim();
}

describe('bot-branch.sh from a worktree (#1224)', () => {
  let sandbox, main, wt;

  before(() => {
    sandbox = mkdtempSync(join(tmpdir(), 'bot-branch-'));
    const origin = join(sandbox, 'origin.git');
    main = join(sandbox, 'repo');
    git(sandbox, 'init', '-q', '--bare', '-b', 'main', origin);
    git(sandbox, 'init', '-q', '-b', 'main', main);
    git(main, 'config', 'user.email', 't@example.invalid');
    git(main, 'config', 'user.name', 't');
    mkdirSync(join(main, 'scripts/lib'), { recursive: true });
    copyFileSync(resolve(REPO_ROOT, 'scripts/bot-branch.sh'), join(main, 'scripts/bot-branch.sh'));
    copyFileSync(resolve(REPO_ROOT, 'scripts/lib/repo-guard.sh'), join(main, 'scripts/lib/repo-guard.sh'));
    writeFileSync(join(main, '.gitignore'), '.claude/\n');
    git(main, 'add', '.');
    git(main, 'commit', '-q', '-m', 'init');
    git(main, 'remote', 'add', 'origin', origin);
    git(main, 'push', '-q', '-u', 'origin', 'main');
    wt = join(main, '.claude/worktrees/agent-x');
    git(main, 'worktree', 'add', '-q', '-b', 'worktree-agent-x', wt, 'main');
  });

  after(() => rmSync(sandbox, { recursive: true, force: true }));

  it('create puts the WORKTREE on bot/issue-N and never switches the main checkout', () => {
    const r = spawnSync(join(wt, 'scripts/bot-branch.sh'), ['create', '7'], {
      cwd: wt,
      encoding: 'utf-8',
    });
    assert.equal(r.status, 0, r.stderr);
    assert.equal(git(wt, 'branch', '--show-current'), 'bot/issue-7');
    assert.equal(git(main, 'branch', '--show-current'), 'main');
    // The EXIT trap put main back, so HEAD alone can't prove it: the main
    // checkout's HEAD reflog must show no checkout of the bot branch at all.
    const reflog = git(main, 'reflog', 'show', 'HEAD', '--format=%gs');
    assert.doesNotMatch(reflog, /bot\/issue-7/);
  });
});
