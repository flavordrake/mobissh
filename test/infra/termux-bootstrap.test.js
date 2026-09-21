/**
 * test/infra/termux-bootstrap.test.js
 *
 * scripts/termux-bootstrap.sh (#499 E1 / E2) — the curl|bash installer whose URL
 * is published in the script header, so it must stay syntax-clean and must refuse
 * to touch the network outside Termux.
 *
 * Relocated from tests/scripts/termux-bootstrap.test.js (a Playwright-runner test
 * of a shell script) when the PWA was retired (#1205). Runner is node:test so it
 * needs no node_modules and runs inside agent worktrees; see scripts/test-infra.sh.
 *
 * E3-E7 are device/manual-only and are tracked in the spec as U-class.
 */

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const { spawnSync } = require('node:child_process');

const SCRIPT_PATH = path.resolve(__dirname, '../../scripts/termux-bootstrap.sh');

describe('scripts/termux-bootstrap.sh (#499 E1 / E2)', () => {
  it('E1a: file exists at scripts/termux-bootstrap.sh', () => {
    assert.ok(fs.existsSync(SCRIPT_PATH), `expected ${SCRIPT_PATH}`);
  });

  it('E1b: file is executable', () => {
    // Git records only the exec bit; the remaining permission bits come from the
    // checkout's umask (022 in the main checkout, 002 in an agent worktree), so
    // asserting the literal 0755 fails for an environment reason, not a real one.
    const st = fs.statSync(SCRIPT_PATH);
    assert.notEqual(st.mode & 0o111, 0, `not executable: ${(st.mode & 0o777).toString(8)}`);
  });

  it('E1c: bash -n syntax check passes', () => {
    const res = spawnSync('bash', ['-n', SCRIPT_PATH], { encoding: 'utf8' });
    assert.equal(res.status, 0, `stderr: ${res.stderr}`);
  });

  it('E1d: shellcheck passes (when available)', (t) => {
    if (spawnSync('which', ['shellcheck']).status !== 0) {
      t.skip('shellcheck not installed in this environment');
      return;
    }
    const res = spawnSync('shellcheck', [SCRIPT_PATH], { encoding: 'utf8' });
    assert.equal(res.status, 0, `shellcheck output: ${res.stdout}\n${res.stderr}`);
  });

  it('E2: outside Termux, exits non-zero with single human-readable stderr line', () => {
    // We're definitely not in Termux here — no $PREFIX/com.termux path, no
    // `pkg` binary. Run the script under a clean env that strips any
    // accidentally-set Termux hints.
    const env = { ...process.env };
    delete env.PREFIX;
    delete env.TERMUX_VERSION;
    delete env.TERMUX_APP_PID;
    // Force PATH to a known-safe set without `pkg`
    env.PATH = '/usr/bin:/bin';

    const res = spawnSync(SCRIPT_PATH, [], { encoding: 'utf8', env, timeout: 15000 });
    assert.notEqual(res.status, 0, 'must exit non-zero outside Termux');

    const lines = res.stderr.split('\n').filter((s) => s.trim().length > 0);
    assert.equal(lines.length, 1);
    // Message mentions Termux somewhere — the user must be able to tell
    // why the script aborted from a single line.
    assert.match(lines[0].toLowerCase(), /termux/);
  });

  it('E2b: outside Termux, does NOT invoke pkg / git clone / network', () => {
    // Replace PATH with a sandbox that shadows pkg, git, curl, wget with
    // bombs that record an invocation. Any call would write to the sentinel
    // file; we expect the file to be empty after the script aborts.
    const sandbox = fs.mkdtempSync(path.join(os.tmpdir(), 'termux-bootstrap-sb-'));
    const sentinel = path.join(sandbox, 'invoked.log');
    fs.writeFileSync(sentinel, '');

    for (const name of ['pkg', 'git', 'curl', 'wget', 'npm', 'node']) {
      const wrap = path.join(sandbox, name);
      fs.writeFileSync(wrap, `#!/bin/sh\necho "${name} $*" >> "${sentinel}"\nexit 1\n`);
      fs.chmodSync(wrap, 0o755);
    }

    const env = { ...process.env };
    delete env.PREFIX;
    delete env.TERMUX_VERSION;
    delete env.TERMUX_APP_PID;
    env.PATH = `${sandbox}:/usr/bin:/bin`;

    spawnSync(SCRIPT_PATH, [], { encoding: 'utf8', env, timeout: 15000 });
    const log = fs.readFileSync(sentinel, 'utf8');
    assert.equal(log, '', 'no package manager / git / curl invocation should have happened');

    try { fs.rmSync(sandbox, { recursive: true, force: true }); } catch { /* ignore */ }
  });
});
