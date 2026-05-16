/**
 * tests/scripts/termux-bootstrap.test.js
 *
 * Red baseline for issue #499 — scripts/termux-bootstrap.sh.
 *
 * Covers:
 *   E1   Script is executable, bash-syntax-clean, and (if shellcheck is
 *        available) shellcheck-clean.
 *   E2   Script aborts cleanly with a single human-readable stderr line and
 *        non-zero exit when run outside Termux. Does NOT call pkg/git/network.
 *
 * Pre-implementation: scripts/termux-bootstrap.sh does not exist. The tests
 * fail because the file is missing. Acceptable red baseline.
 *
 * E3-E7 are device/manual-only and are tracked in the spec as U-class
 * (not auto-testable on this host).
 */

const { test, expect } = require('@playwright/test');
const path = require('node:path');
const fs = require('node:fs');
const { spawnSync } = require('node:child_process');

const SCRIPT_PATH = path.resolve(__dirname, '../../scripts/termux-bootstrap.sh');

test.describe('scripts/termux-bootstrap.sh (#499 E1 / E2)', () => {

  test('E1a: file exists at scripts/termux-bootstrap.sh', () => {
    expect(fs.existsSync(SCRIPT_PATH), `expected ${SCRIPT_PATH}`).toBe(true);
  });

  test('E1b: file mode is 0755 (executable)', () => {
    const st = fs.statSync(SCRIPT_PATH);
    // Lowest 9 bits of the mode == rwxr-xr-x
    expect((st.mode & 0o777).toString(8)).toBe('755');
  });

  test('E1c: bash -n syntax check passes', () => {
    const res = spawnSync('bash', ['-n', SCRIPT_PATH], { encoding: 'utf8' });
    expect(res.status, `stderr: ${res.stderr}`).toBe(0);
  });

  test('E1d: shellcheck passes (when available)', () => {
    const which = spawnSync('which', ['shellcheck']);
    if (which.status !== 0) {
      test.skip(true, 'shellcheck not installed in this environment');
    }
    const res = spawnSync('shellcheck', [SCRIPT_PATH], { encoding: 'utf8' });
    expect(res.status, `shellcheck output: ${res.stdout}\n${res.stderr}`).toBe(0);
  });

  test('E2: outside Termux, exits non-zero with single human-readable stderr line', () => {
    // We're definitely not in Termux here — no $PREFIX/com.termux path, no
    // `pkg` binary. Run the script under a clean env that strips any
    // accidentally-set Termux hints.
    const env = { ...process.env };
    delete env.PREFIX;
    delete env.TERMUX_VERSION;
    delete env.TERMUX_APP_PID;
    // Force PATH to a known-safe set without `pkg`
    env.PATH = '/usr/bin:/bin';

    const res = spawnSync(SCRIPT_PATH, [], { encoding: 'utf8', env, timeout: 15_000 });
    expect(res.status, 'must exit non-zero outside Termux').not.toBe(0);

    const lines = res.stderr.split('\n').filter((s) => s.trim().length > 0);
    expect(lines.length).toBe(1);
    // Message mentions Termux somewhere — the user must be able to tell
    // why the script aborted from a single line.
    expect(lines[0].toLowerCase()).toContain('termux');
  });

  test('E2b: outside Termux, does NOT invoke pkg / git clone / network', () => {
    // Replace PATH with a sandbox that shadows pkg, git, curl, wget with
    // bombs that record an invocation. Any call would write to the sentinel
    // file; we expect the file to be empty after the script aborts.
    const sandbox = fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'termux-bootstrap-sb-'));
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

    spawnSync(SCRIPT_PATH, [], { encoding: 'utf8', env, timeout: 15_000 });
    const log = fs.readFileSync(sentinel, 'utf8');
    expect(log, 'no package manager / git / curl invocation should have happened').toBe('');

    // Cleanup
    try { fs.rmSync(sandbox, { recursive: true, force: true }); } catch { /* ignore */ }
  });
});
