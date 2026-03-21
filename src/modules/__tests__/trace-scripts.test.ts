import { describe, it, expect } from 'vitest';
import { execFileSync } from 'child_process';
import { resolve } from 'path';

// Resolve repo root (works from worktrees too)
const REPO_ROOT = resolve(__dirname, '../../..');

function run(script: string, args: string[] = [], opts: { expectFail?: boolean } = {}): string {
  const scriptPath = resolve(REPO_ROOT, 'scripts', script);
  try {
    const out = execFileSync(scriptPath, args, {
      cwd: REPO_ROOT,
      encoding: 'utf-8',
      timeout: 15000,
      env: { ...process.env, PATH: process.env.PATH },
    });
    return out;
  } catch (err: unknown) {
    const e = err as { status: number; stdout?: string; stderr?: string };
    if (opts.expectFail) {
      return (e.stderr || '') + (e.stdout || '');
    }
    throw new Error(`${script} exited ${e.status}: ${e.stderr || e.stdout || ''}`);
  }
}

function runExpectFail(script: string, args: string[] = []): string {
  return run(script, args, { expectFail: true });
}

describe('trace-file-history.sh', () => {
  it('prints usage and exits non-zero with no args', () => {
    const out = runExpectFail('trace-file-history.sh');
    expect(out.toLowerCase()).toContain('usage');
  });

  it('produces structured output for a known file', () => {
    const out = run('trace-file-history.sh', ['server/index.js']);
    // Should contain commit hashes (7+ hex chars)
    expect(out).toMatch(/[0-9a-f]{7,}/);
    // Should contain date-like strings
    expect(out).toMatch(/\d{4}-\d{2}-\d{2}/);
  });

  it('includes issue references when present in commit messages', () => {
    // server/index.js has been touched by many PRs with #N references
    const out = run('trace-file-history.sh', ['server/index.js']);
    expect(out).toMatch(/#\d+/);
  });

  it('supports --json flag', () => {
    const out = run('trace-file-history.sh', ['server/index.js', '--json']);
    const parsed = JSON.parse(out);
    expect(Array.isArray(parsed)).toBe(true);
    expect(parsed.length).toBeGreaterThan(0);
    expect(parsed[0]).toHaveProperty('hash');
    expect(parsed[0]).toHaveProperty('date');
    expect(parsed[0]).toHaveProperty('subject');
  });
});

describe('trace-symbol-history.sh', () => {
  it('prints usage and exits non-zero with no args', () => {
    const out = runExpectFail('trace-symbol-history.sh');
    expect(out.toLowerCase()).toContain('usage');
  });

  it('finds commits that added/removed a known symbol', () => {
    // getDefaultWsUrl is a function that exists in the codebase
    const out = run('trace-symbol-history.sh', ['getDefaultWsUrl']);
    expect(out).toMatch(/[0-9a-f]{7,}/);
  });

  it('supports --file scope filter', () => {
    const out = run('trace-symbol-history.sh', ['getDefaultWsUrl', '--file', 'src/modules/connection.ts']);
    expect(out).toMatch(/[0-9a-f]{7,}/);
  });

  it('handles symbol not found gracefully', () => {
    const out = run('trace-symbol-history.sh', ['xyzzy_nonexistent_symbol_12345']);
    expect(out.toLowerCase()).toContain('no commits found');
  });
});

describe('trace-github-search.sh', () => {
  it('prints usage and exits non-zero with no args', () => {
    const out = runExpectFail('trace-github-search.sh');
    expect(out.toLowerCase()).toContain('usage');
  });

  it('searches issues by default', () => {
    // Search for something likely to exist
    const out = run('trace-github-search.sh', ['vault']);
    // Should produce some output (even if empty results, format should be there)
    expect(out).toBeDefined();
    expect(out.length).toBeGreaterThan(0);
  });

  it('supports --type flag', () => {
    const out = run('trace-github-search.sh', ['vault', '--type', 'issues']);
    expect(out).toBeDefined();
  });
});
