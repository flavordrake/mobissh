/**
 * test/infra/approval-bridge-flag.test.js
 *
 * #1251: hooks/mobissh-bridge.sh is wired into the owner's Claude Code
 * settings as a PermissionRequest hook and answered `allow` whenever no phone
 * client was listening, i.e. always, so every permission prompt on fd-dev
 * was auto-approved. It is now OFF unless explicitly enabled (owner directive
 * 2026-10-02: "disable that approval hook behind a feature flag"). Off means
 * no output at all, so Claude Code falls back to its normal permission flow.
 */

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const { mkdtempSync, mkdirSync, writeFileSync, rmSync } = require('node:fs');
const { resolve, join } = require('node:path');
const { tmpdir } = require('node:os');

const HOOK = resolve(__dirname, '../../hooks/mobissh-bridge.sh');
const PERMISSION_REQUEST = JSON.stringify({
  hook_event_name: 'PermissionRequest',
  tool_name: 'Bash',
  tool_input: { command: 'rm -rf /tmp/x' },
});

function runHook(env, input = PERMISSION_REQUEST) {
  const home = mkdtempSync(join(tmpdir(), 'bridge-home-'));
  try {
    const r = spawnSync('bash', [HOOK], {
      input,
      encoding: 'utf-8',
      timeout: 30000,
      env: {
        PATH: process.env.PATH,
        HOME: home,
        // Unroutable: if the hook ever reaches the network it fails fast.
        MOBISSH_BRIDGE_URL: 'http://127.0.0.1:9',
        ...env(home),
      },
    });
    return r;
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
}

describe('approval bridge feature flag (#1251)', () => {
  it('is OFF by default: no decision is emitted for a PermissionRequest', () => {
    const r = runHook(() => ({}));
    assert.equal(r.status, 0, r.stderr);
    assert.equal(r.stdout.trim(), '', 'off must print nothing, so Claude Code prompts normally');
  });

  it('is OFF by default for non-approval events too (nothing sent, nothing printed)', () => {
    const r = runHook(() => ({}), JSON.stringify({ hook_event_name: 'Stop' }));
    assert.equal(r.status, 0, r.stderr);
    assert.equal(r.stdout.trim(), '');
  });

  it('MOBISSH_APPROVAL_BRIDGE=1 re-enables the legacy behaviour', () => {
    const r = runHook(() => ({ MOBISSH_APPROVAL_BRIDGE: '1' }));
    assert.equal(r.status, 0, r.stderr);
    // Unreachable server + legacy behaviour = the old fail-open allow.
    assert.match(r.stdout, /"behavior":"allow"/);
  });

  it('the flag file ~/.claude/mobissh-approval-bridge.enabled re-enables it', () => {
    const r = runHook((home) => {
      mkdirSync(join(home, '.claude'), { recursive: true });
      writeFileSync(join(home, '.claude', 'mobissh-approval-bridge.enabled'), '');
      return {};
    });
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /"behavior":"allow"/);
  });
});
