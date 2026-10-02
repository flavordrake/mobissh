/**
 * test/infra/doc-drift.test.js
 *
 * scripts/doc-drift.sh (#1240, fleet standard from opsurface #229) checks both
 * directions: a script something calls must be named by a doc, and every path
 * a doc names must exist. Each case builds a throwaway fixture tree and runs the
 * real script against it with --root.
 */

const { describe, it, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const { mkdtempSync, mkdirSync, writeFileSync, rmSync } = require('node:fs');
const { resolve, join, dirname } = require('node:path');
const { tmpdir } = require('node:os');

const SCRIPT = resolve(__dirname, '../../scripts/doc-drift.sh');

let roots = [];
function fixture(files) {
  const root = mkdtempSync(join(tmpdir(), 'doc-drift-'));
  roots.push(root);
  for (const [path, body] of Object.entries(files)) {
    mkdirSync(dirname(join(root, path)), { recursive: true });
    writeFileSync(join(root, path), body);
  }
  return root;
}
function run(root, mode) {
  return spawnSync(SCRIPT, [mode, '--root', root], { encoding: 'utf-8' });
}

afterEach(() => {
  for (const r of roots) rmSync(r, { recursive: true, force: true });
  roots = [];
});

describe('doc-drift.sh', () => {
  it('passes a consistent tree', () => {
    const root = fixture({
      'scripts/a.sh': '#!/bin/sh\n# scripts/a.sh header\nscripts/b.sh\n',
      'scripts/b.sh': '#!/bin/sh\n',
      'README.md': 'Run `scripts/b.sh`.\n',
    });
    const r = run(root, '--block');
    assert.equal(r.status, 0, r.stdout);
    assert.match(r.stdout, /\+ doc-drift: consistent/);
  });

  it('flags a called script no doc names, but not a self-mention', () => {
    const root = fixture({
      'scripts/a.sh': '#!/bin/sh\n# scripts/a.sh header\nscripts/b.sh\n',
      'scripts/b.sh': '#!/bin/sh\n',
      'README.md': 'nothing here\n',
    });
    const r = run(root, '--block');
    assert.equal(r.status, 1);
    assert.match(r.stdout, /CALLED-BUT-UNDOCUMENTED: scripts\/b\.sh/);
    assert.doesNotMatch(r.stdout, /scripts\/a\.sh/);
  });

  it('flags a documented path that does not exist', () => {
    const root = fixture({
      'docs/x.md': 'See scripts/gone.sh and docs/missing.md.\n',
    });
    const r = run(root, '--block');
    assert.equal(r.status, 1);
    assert.match(r.stdout, /DOCUMENTED-BUT-MISSING: scripts\/gone\.sh/);
    assert.match(r.stdout, /DOCUMENTED-BUT-MISSING: docs\/missing\.md/);
  });

  it('a documented directory covers the scripts under it', () => {
    const root = fixture({
      'hooks/pre-commit': 'scripts/lib/x.sh\n',
      'scripts/lib/x.sh': '#!/bin/sh\n',
      'developer.md': 'Helpers live in scripts/lib/.\n',
    });
    assert.equal(run(root, '--block').status, 0);
  });

  it('honours the ignore list, and --warn never fails', () => {
    const root = fixture({
      'docs/x.md': 'scripts/example.sh\n',
      'scripts/doc-drift-ignore.txt': '# placeholder name in an example\nscripts/example.sh\n',
    });
    assert.equal(run(root, '--block').status, 0);
    const warn = run(fixture({ 'docs/y.md': 'scripts/gone.sh\n' }), '--warn');
    assert.equal(warn.status, 0);
    assert.match(warn.stdout, /1 finding/);
  });
});
