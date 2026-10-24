/**
 * test/infra/worktree-prune-merged.test.js
 *
 * scripts/worktree-prune-merged.sh removes ONLY agent worktrees whose HEAD is
 * already on origin/main and that hold nothing uncommitted (the build-runner
 * hook in scripts/flutter-cmd.sh excepted). Unmerged work, other tracked
 * changes and untracked files (test-history, new files) keep the worktree.
 *
 * Sandbox: bare origin + main checkout + worktrees under .claude/worktrees/,
 * holding copies of the real scripts so REPO_ROOT resolves inside it.
 */

const { describe, it, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync, spawnSync } = require('node:child_process');
const { mkdtempSync, mkdirSync, copyFileSync, rmSync, writeFileSync, existsSync, appendFileSync } = require('node:fs');
const { resolve, join } = require('node:path');
const { tmpdir } = require('node:os');

const REPO_ROOT = resolve(__dirname, '../..');

function git(cwd, ...args) {
  return execFileSync('git', args, { cwd, encoding: 'utf-8' }).trim();
}

describe('worktree-prune-merged.sh', () => {
  let sandbox, main, result;
  const wt = (n) => join(main, '.claude/worktrees', `agent-${n}`);

  function addWorktree(n) {
    git(main, 'worktree', 'add', '-q', '-b', `worktree-agent-${n}`, wt(n), 'main');
    git(wt(n), 'config', 'user.email', 't@example.invalid');
    git(wt(n), 'config', 'user.name', 't');
  }

  before(() => {
    sandbox = mkdtempSync(join(tmpdir(), 'wt-prune-'));
    const origin = join(sandbox, 'origin.git');
    main = join(sandbox, 'repo');
    git(sandbox, 'init', '-q', '--bare', '-b', 'main', origin);
    git(sandbox, 'init', '-q', '-b', 'main', main);
    git(main, 'config', 'user.email', 't@example.invalid');
    git(main, 'config', 'user.name', 't');
    mkdirSync(join(main, 'scripts/lib'), { recursive: true });
    copyFileSync(resolve(REPO_ROOT, 'scripts/worktree-prune-merged.sh'), join(main, 'scripts/worktree-prune-merged.sh'));
    copyFileSync(resolve(REPO_ROOT, 'scripts/lib/repo-guard.sh'), join(main, 'scripts/lib/repo-guard.sh'));
    writeFileSync(join(main, 'scripts/flutter-cmd.sh'), '#!/bin/sh\n');
    writeFileSync(join(main, 'README'), 'r\n');
    writeFileSync(join(main, '.gitignore'), '.claude/\nbuild/\n');
    git(main, 'add', '.');
    git(main, 'commit', '-q', '-m', 'init');
    git(main, 'remote', 'add', 'origin', origin);
    git(main, 'push', '-q', '-u', 'origin', 'main');

    addWorktree('merged');
    addWorktree('hook');
    appendFileSync(join(wt('hook'), 'scripts/flutter-cmd.sh'), 'source /x\n');
    addWorktree('ignored');
    mkdirSync(join(wt('ignored'), 'build'));
    writeFileSync(join(wt('ignored'), 'build/out'), 'o\n');
    addWorktree('unmerged');
    writeFileSync(join(wt('unmerged'), 'new.txt'), 'n\n');
    git(wt('unmerged'), 'add', 'new.txt');
    git(wt('unmerged'), 'commit', '-q', '-m', 'work');
    addWorktree('edited');
    appendFileSync(join(wt('edited'), 'README'), 'edit\n');
    addWorktree('untracked');
    mkdirSync(join(wt('untracked'), 'test-history'));
    writeFileSync(join(wt('untracked'), 'test-history/run.log'), 'l\n');

    result = spawnSync(join(main, 'scripts/worktree-prune-merged.sh'), [], { cwd: main, encoding: 'utf-8' });
  });

  after(() => rmSync(sandbox, { recursive: true, force: true }));

  it('exits 0 and reports what it freed', () => {
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /removed 3, kept 3; freed/);
  });

  it('removes merged worktrees: clean, hook-only change, ignored build output', () => {
    for (const n of ['merged', 'hook', 'ignored']) assert.equal(existsSync(wt(n)), false, n);
  });

  it('keeps unmerged work, other tracked edits and untracked files', () => {
    for (const n of ['unmerged', 'edited', 'untracked']) assert.equal(existsSync(wt(n)), true, n);
    assert.match(result.stdout, /keep {3}agent-unmerged \(not on origin\/main\)/);
    assert.match(result.stdout, /keep {3}agent-edited \(tracked changes: README\)/);
    assert.match(result.stdout, /keep {3}agent-untracked \(untracked: test-history\/run.log\)/);
  });

  it('never deletes branches', () => {
    assert.match(git(main, 'branch', '--list', 'worktree-agent-merged'), /worktree-agent-merged/);
  });
});
