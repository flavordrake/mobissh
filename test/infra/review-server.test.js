/**
 * test/infra/review-server.test.js
 *
 * #1286: tools/review-server/serve.js built shell strings from a user-supplied
 * issue title (POST /file-issue) and from report.json (POST /file-test-issue)
 * and ran them through execSync, so `$(...)` and backticks in a title executed
 * on the dev host. Both routes now go through fileIssue(), which hands an argv
 * array to scripts/gh-file-issue.sh with no shell. `gh` is a fake on PATH that
 * records its argv.
 *
 * #1287: REVIEW_PORT set with no --port read argv[0] (operator precedence), so
 * the server failed to bind. Env wins, then --port, else 9090.
 */

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');

const REPO_ROOT = path.resolve(__dirname, '../..');
const SERVE = path.join(REPO_ROOT, 'tools/review-server/serve.js');
const SRC = fs.readFileSync(SERVE, 'utf8');

function tmpdir(tag) {
  return fs.mkdtempSync(path.join(os.tmpdir(), `rs1286-${tag}-`));
}

/** A fake `gh` on PATH: records argv one per line, prints an issue URL. */
function fakeGh(dir, log) {
  const bin = path.join(dir, 'bin');
  fs.mkdirSync(bin);
  fs.writeFileSync(path.join(bin, 'gh'), [
    '#!/usr/bin/env bash',
    `printf '%s\\n' "$@" > "${log}"`,
    'echo https://github.com/example/mobissh/issues/1',
  ].join('\n'));
  fs.chmodSync(path.join(bin, 'gh'), 0o755);
  return bin;
}

function freePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.listen(0, '127.0.0.1', () => {
      const { port } = srv.address();
      srv.close(() => resolve(port));
    });
    srv.on('error', reject);
  });
}

/** Start serve.js, resolve with its first stdout line, then kill it. */
function bootLine(env, args) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [SERVE, ...args], {
      env: { PATH: process.env.PATH, ...env },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let out = '';
    let err = '';
    const done = (line) => { child.kill(); resolve({ line, err }); };
    const timer = setTimeout(() => done(''), 10000);
    child.stdout.on('data', (d) => {
      out += d;
      const nl = out.indexOf('\n');
      if (nl !== -1) { clearTimeout(timer); done(out.slice(0, nl)); }
    });
    child.stderr.on('data', (d) => { err += d; });
    child.on('exit', () => { clearTimeout(timer); resolve({ line: out.split('\n')[0], err }); });
  });
}

describe('review-server issue filing is shell-free (#1286)', () => {
  it('a hostile title never executes and reaches gh literally', () => {
    const dir = tmpdir('inject');
    const marker1 = path.join(dir, 'pwned-subshell');
    const marker2 = path.join(dir, 'pwned-backtick');
    const log = path.join(dir, 'gh-argv.txt');
    const bin = fakeGh(dir, log);
    const bodyFile = path.join(dir, 'body.md');
    fs.writeFileSync(bodyFile, 'body\n');
    const title = `bug: $(touch ${marker1}) \`touch ${marker2}\` "quoted" ; echo x`;

    const savedPath = process.env.PATH;
    process.env.PATH = `${bin}:${savedPath}`;
    let result;
    try {
      const serve = require(SERVE);
      result = serve.fileIssue(title, bodyFile);
    } finally {
      process.env.PATH = savedPath;
    }

    assert.ok(!fs.existsSync(marker1), 'subshell in the title must not run');
    assert.ok(!fs.existsSync(marker2), 'backticks in the title must not run');
    assert.equal(result.ghError, '', 'filing succeeded through the fake gh');
    assert.equal(result.issueUrl, 'https://github.com/example/mobissh/issues/1');
    const argv = fs.readFileSync(log, 'utf8').split('\n');
    assert.equal(argv[argv.indexOf('--title') + 1], title, 'gh receives the literal title as one argument');
  });

  it('serve.js has no execSync and no shell-string command building', () => {
    assert.doesNotMatch(SRC, /execSync|\bexec\(|shell:\s*true/);
    assert.doesNotMatch(SRC, /gh-file-issue\.sh --title/);
  });
});

describe('review-server port precedence (#1287)', () => {
  it('REVIEW_PORT with no --port binds the env value, not argv[0]', async () => {
    const port = await freePort();
    const { line, err } = await bootLine({ REVIEW_PORT: String(port) }, []);
    assert.equal(line, `Review server: http://localhost:${port}`, err);
  });

  it('--port is honoured when REVIEW_PORT is unset', async () => {
    const port = await freePort();
    const { line, err } = await bootLine({}, ['--port', String(port)]);
    assert.equal(line, `Review server: http://localhost:${port}`, err);
  });

  it('resolvePort: env first, then --port, else 9090', () => {
    const { resolvePort } = require(SERVE);
    assert.equal(resolvePort({ REVIEW_PORT: '7777' }, ['node', 'serve.js', '--port', '8888']), 7777);
    assert.equal(resolvePort({}, ['node', 'serve.js', '--port', '8888']), 8888);
    assert.equal(resolvePort({}, ['node', 'serve.js']), 9090);
  });
});
