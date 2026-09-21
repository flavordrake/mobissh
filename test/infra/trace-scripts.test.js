/**
 * test/infra/trace-scripts.test.js
 *
 * The TRACE tooling the agent-trace skill invokes: scripts/trace-file-history.sh,
 * scripts/trace-symbol-history.sh, scripts/trace-github-search.sh.
 *
 * Relocated from src/modules/__tests__/trace-scripts.test.ts when the PWA was
 * retired (#1205). Runner is node:test so it needs no node_modules and runs
 * inside agent worktrees; see scripts/test-infra.sh.
 */

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync, spawnSync } = require('node:child_process');
const { resolve } = require('node:path');

const REPO_ROOT = resolve(__dirname, '../..');

function run(script, args = [], opts = {}) {
  const scriptPath = resolve(REPO_ROOT, 'scripts', script);
  try {
    return execFileSync(scriptPath, args, {
      cwd: REPO_ROOT,
      encoding: 'utf-8',
      timeout: 15000,
      env: { ...process.env, PATH: process.env.PATH },
    });
  } catch (e) {
    if (opts.expectFail) {
      return (e.stderr || '') + (e.stdout || '');
    }
    throw new Error(`${script} exited ${e.status}: ${e.stderr || e.stdout || ''}`);
  }
}

function runExpectFail(script, args = []) {
  return run(script, args, { expectFail: true });
}

// trace-github-search.sh is a thin wrapper over `gh search`; with no GitHub
// credentials there is nothing for it to assert against, so that block is
// skipped LOUDLY rather than failed. CI supplies GH_TOKEN, fd-dev is gh-authed.
const ghAuthed = spawnSync('gh', ['auth', 'status'], { encoding: 'utf-8' }).status === 0;

describe('trace-file-history.sh', () => {
  it('prints usage and exits non-zero with no args', () => {
    const out = runExpectFail('trace-file-history.sh');
    assert.match(out.toLowerCase(), /usage/);
  });

  it('produces structured output for a known file', () => {
    const out = run('trace-file-history.sh', ['server/index.js']);
    // Should contain commit hashes (7+ hex chars)
    assert.match(out, /[0-9a-f]{7,}/);
    // Should contain date-like strings
    assert.match(out, /\d{4}-\d{2}-\d{2}/);
  });

  it('includes issue references when present in commit messages', () => {
    // server/index.js has been touched by many PRs with #N references
    const out = run('trace-file-history.sh', ['server/index.js']);
    assert.match(out, /#\d+/);
  });

  it('supports --json flag', () => {
    const out = run('trace-file-history.sh', ['server/index.js', '--json']);
    const parsed = JSON.parse(out);
    assert.ok(Array.isArray(parsed));
    assert.ok(parsed.length > 0);
    assert.ok(Object.hasOwn(parsed[0], 'hash'));
    assert.ok(Object.hasOwn(parsed[0], 'date'));
    assert.ok(Object.hasOwn(parsed[0], 'subject'));
  });
});

describe('trace-symbol-history.sh', () => {
  it('prints usage and exits non-zero with no args', () => {
    const out = runExpectFail('trace-symbol-history.sh');
    assert.match(out.toLowerCase(), /usage/);
  });

  it('finds commits that added/removed a known symbol', () => {
    // rewriteManifest is a live function in server/manifest.js
    const out = run('trace-symbol-history.sh', ['rewriteManifest']);
    assert.match(out, /[0-9a-f]{7,}/);
  });

  it('supports --file scope filter', () => {
    const out = run('trace-symbol-history.sh', ['rewriteManifest', '--file', 'server/manifest.js']);
    assert.match(out, /[0-9a-f]{7,}/);
  });

  it('handles symbol not found gracefully', () => {
    // Scope to a file that definitely doesn't contain our search term
    const out = run('trace-symbol-history.sh', ['xyzzy_never_existed', '--file', 'package.json']);
    assert.match(out.toLowerCase(), /no commits found/);
  });
});

describe('trace-github-search.sh', { skip: ghAuthed ? false : 'gh is not authenticated here' }, () => {
  it('prints usage and exits non-zero with no args', () => {
    const out = runExpectFail('trace-github-search.sh');
    assert.match(out.toLowerCase(), /usage/);
  });

  it('searches issues by default', () => {
    const out = run('trace-github-search.sh', ['vault']);
    assert.ok(out.length > 0);
  });

  it('supports --type flag', () => {
    const out = run('trace-github-search.sh', ['vault', '--type', 'issues']);
    assert.notEqual(out, undefined);
  });
});
