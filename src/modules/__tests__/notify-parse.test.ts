import { describe, it, expect } from 'vitest';
import { execFileSync } from 'child_process';
import { resolve } from 'path';

const REPO_ROOT = resolve(__dirname, '../../..');
const SCRIPT = resolve(REPO_ROOT, 'scripts/notify-parse.sh');

function parse(json: Record<string, unknown>): string {
  const input = JSON.stringify(json);
  const out = execFileSync('bash', [SCRIPT], {
    cwd: REPO_ROOT,
    encoding: 'utf-8',
    input,
    timeout: 5000,
  });
  return out.trim();
}

describe('notify-parse.sh', () => {
  describe('PermissionRequest events', () => {
    it('extracts Bash tool with command', () => {
      const msg = parse({
        hook_event_name: 'PermissionRequest',
        tool_name: 'Bash',
        tool_input: { command: 'git status' },
      });
      expect(msg).toBe('Approve: Bash \u2014 git status');
    });

    it('extracts Edit tool with file path basename', () => {
      const msg = parse({
        hook_event_name: 'PermissionRequest',
        tool_name: 'Edit',
        tool_input: { file_path: '/home/dev/workspace/mobissh/src/modules/ui.ts' },
      });
      expect(msg).toContain('Approve: Edit');
      expect(msg).toContain('ui.ts');
    });

    it('extracts Write tool with file path basename', () => {
      const msg = parse({
        hook_event_name: 'PermissionRequest',
        tool_name: 'Write',
        tool_input: { file_path: '/home/dev/workspace/mobissh/src/modules/settings.ts' },
      });
      expect(msg).toContain('Approve: Write');
      expect(msg).toContain('settings.ts');
    });

    it('shortens long commands to fit 80-char limit', () => {
      const longCmd = 'find /home/dev/workspace/mobissh -name "*.ts" -exec grep -l "import" {} \\; | sort | head -20';
      const msg = parse({
        hook_event_name: 'PermissionRequest',
        tool_name: 'Bash',
        tool_input: { command: longCmd },
      });
      expect(msg.length).toBeLessThanOrEqual(80);
    });

    it('shows basename for file paths', () => {
      const msg = parse({
        hook_event_name: 'PermissionRequest',
        tool_name: 'Edit',
        tool_input: { file_path: '/home/dev/workspace/mobissh/src/modules/very-long-module-name.ts' },
      });
      expect(msg).toContain('very-long-module-name.ts');
      // Should NOT contain the full path
      expect(msg).not.toContain('/home/dev');
    });

    it('handles missing tool_input gracefully', () => {
      const msg = parse({
        hook_event_name: 'PermissionRequest',
        tool_name: 'Bash',
      });
      expect(msg).toBe('Approve: Bash');
    });

    it('extracts Grep pattern', () => {
      const msg = parse({
        hook_event_name: 'PermissionRequest',
        tool_name: 'Grep',
        tool_input: { pattern: 'showNotification' },
      });
      expect(msg).toContain('Approve: Grep');
      expect(msg).toContain('showNotification');
    });
  });

  describe('Notification events', () => {
    it('strips unicode box-drawing characters', () => {
      const msg = parse({
        hook_event_name: 'Notification',
        message: '\u2554\u2550\u2550\u2550\u2550\u2550\u2550\u2557 Accept edits \u255a\u2550\u2550\u2550\u2550\u2550\u2550\u255d',
      });
      expect(msg).not.toMatch(/[\u2554\u2557\u255a\u255d\u2550\u2551]/);
      expect(msg).toContain('Accept edits');
    });

    it('strips middle dot separators', () => {
      const msg = parse({
        hook_event_name: 'Notification',
        message: 'accept edits on \u00b7 2 local agents',
      });
      expect(msg).not.toContain('\u00b7');
      expect(msg).toContain('accept edits on');
      expect(msg).toContain('2 local agents');
    });

    it('uses title when message is empty', () => {
      const msg = parse({
        hook_event_name: 'Notification',
        title: 'Task completed',
      });
      expect(msg).toContain('Task completed');
    });

    it('combines title and message with colon', () => {
      const msg = parse({
        hook_event_name: 'Notification',
        title: 'Agent',
        message: 'editing ui.ts',
      });
      expect(msg).toBe('Agent: editing ui.ts');
    });

    it('strips ANSI escape sequences', () => {
      const msg = parse({
        hook_event_name: 'Notification',
        message: '\x1b[1;32mSuccess\x1b[0m: file saved',
      });
      // eslint-disable-next-line no-control-regex
      expect(msg).not.toMatch(/\x1b/);
      expect(msg).toContain('Success');
      expect(msg).toContain('file saved');
    });

    it('collapses multiple spaces to single', () => {
      const msg = parse({
        hook_event_name: 'Notification',
        message: 'editing    file   now',
      });
      expect(msg).toBe('editing file now');
    });
  });

  describe('Stop events', () => {
    it('returns "Claude finished"', () => {
      const msg = parse({
        hook_event_name: 'Stop',
      });
      expect(msg).toBe('Claude finished');
    });
  });

  describe('edge cases', () => {
    it('handles empty JSON input', () => {
      const msg = parse({});
      expect(msg).toBe('');
    });

    it('handles unknown event types with message', () => {
      const msg = parse({
        hook_event_name: 'UnknownEvent',
        message: 'something happened',
      });
      expect(msg).toBe('something happened');
    });

    it('truncates output to max 80 chars', () => {
      const longMsg = 'A'.repeat(200);
      const msg = parse({
        hook_event_name: 'Notification',
        message: longMsg,
      });
      expect(msg.length).toBeLessThanOrEqual(80);
      expect(msg).toMatch(/\.\.\.$/);
    });
  });
});
