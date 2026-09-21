/**
 * test/infra/notify-parse.test.js
 *
 * scripts/notify-parse.sh — turns a Claude Code hook JSON event into the single
 * short line the attention notification shows.
 *
 * Relocated from src/modules/__tests__/notify-parse.test.ts when the PWA was
 * retired (#1205). Runner is node:test so it needs no node_modules and runs
 * inside agent worktrees; see scripts/test-infra.sh.
 */

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { resolve } = require('node:path');

const REPO_ROOT = resolve(__dirname, '../..');
const SCRIPT = resolve(REPO_ROOT, 'scripts/notify-parse.sh');

function parse(json) {
  return execFileSync('bash', [SCRIPT], {
    cwd: REPO_ROOT,
    encoding: 'utf-8',
    input: JSON.stringify(json),
    timeout: 5000,
  }).trim();
}

describe('notify-parse.sh — PermissionRequest events', () => {
  it('extracts Bash tool with command', () => {
    const msg = parse({
      hook_event_name: 'PermissionRequest',
      tool_name: 'Bash',
      tool_input: { command: 'git status' },
    });
    assert.equal(msg, 'Approve: Bash — git status');
  });

  it('extracts Edit tool with file path basename', () => {
    const msg = parse({
      hook_event_name: 'PermissionRequest',
      tool_name: 'Edit',
      tool_input: { file_path: '/home/dev/workspace/mobissh/native/lib/ui.dart' },
    });
    assert.match(msg, /Approve: Edit/);
    assert.match(msg, /ui\.dart/);
  });

  it('extracts Write tool with file path basename', () => {
    const msg = parse({
      hook_event_name: 'PermissionRequest',
      tool_name: 'Write',
      tool_input: { file_path: '/home/dev/workspace/mobissh/native/lib/settings.dart' },
    });
    assert.match(msg, /Approve: Write/);
    assert.match(msg, /settings\.dart/);
  });

  it('shortens long commands to fit 80-char limit', () => {
    const longCmd = 'find /home/dev/workspace/mobissh -name "*.dart" -exec grep -l "import" {} \\; | sort | head -20';
    const msg = parse({
      hook_event_name: 'PermissionRequest',
      tool_name: 'Bash',
      tool_input: { command: longCmd },
    });
    assert.ok(msg.length <= 80, `got ${msg.length} chars: ${msg}`);
  });

  it('shows basename for file paths', () => {
    const msg = parse({
      hook_event_name: 'PermissionRequest',
      tool_name: 'Edit',
      tool_input: { file_path: '/home/dev/workspace/mobissh/native/lib/very-long-module-name.dart' },
    });
    assert.match(msg, /very-long-module-name\.dart/);
    // Should NOT contain the full path
    assert.ok(!msg.includes('/home/dev'));
  });

  it('handles missing tool_input gracefully', () => {
    const msg = parse({ hook_event_name: 'PermissionRequest', tool_name: 'Bash' });
    assert.equal(msg, 'Approve: Bash');
  });

  it('extracts Grep pattern', () => {
    const msg = parse({
      hook_event_name: 'PermissionRequest',
      tool_name: 'Grep',
      tool_input: { pattern: 'showNotification' },
    });
    assert.match(msg, /Approve: Grep/);
    assert.match(msg, /showNotification/);
  });
});

describe('notify-parse.sh — Notification events', () => {
  it('strips unicode box-drawing characters', () => {
    const msg = parse({
      hook_event_name: 'Notification',
      message: '╔══════╗ Accept edits ╚══════╝',
    });
    assert.ok(!/[╔╗╚╝═║]/.test(msg));
    assert.match(msg, /Accept edits/);
  });

  it('strips middle dot separators', () => {
    const msg = parse({
      hook_event_name: 'Notification',
      message: 'accept edits on · 2 local agents',
    });
    assert.ok(!msg.includes('·'));
    assert.match(msg, /accept edits on/);
    assert.match(msg, /2 local agents/);
  });

  it('uses title when message is empty', () => {
    const msg = parse({ hook_event_name: 'Notification', title: 'Task completed' });
    assert.match(msg, /Task completed/);
  });

  it('combines title and message with colon', () => {
    const msg = parse({ hook_event_name: 'Notification', title: 'Agent', message: 'editing ui.dart' });
    assert.equal(msg, 'Agent: editing ui.dart');
  });

  it('strips ANSI escape sequences', () => {
    const msg = parse({
      hook_event_name: 'Notification',
      message: '\x1b[1;32mSuccess\x1b[0m: file saved',
    });
    assert.ok(!msg.includes('\x1b'));
    assert.match(msg, /Success/);
    assert.match(msg, /file saved/);
  });

  it('collapses multiple spaces to single', () => {
    const msg = parse({ hook_event_name: 'Notification', message: 'editing    file   now' });
    assert.equal(msg, 'editing file now');
  });
});

describe('notify-parse.sh — Stop events and edge cases', () => {
  it('returns "Claude finished" for Stop', () => {
    assert.equal(parse({ hook_event_name: 'Stop' }), 'Claude finished');
  });

  it('handles empty JSON input', () => {
    assert.equal(parse({}), '');
  });

  it('handles unknown event types with message', () => {
    const msg = parse({ hook_event_name: 'UnknownEvent', message: 'something happened' });
    assert.equal(msg, 'something happened');
  });

  it('truncates output to max 80 chars', () => {
    const msg = parse({ hook_event_name: 'Notification', message: 'A'.repeat(200) });
    assert.ok(msg.length <= 80);
    assert.match(msg, /\.\.\.$/);
  });
});
