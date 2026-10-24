/**
 * test/infra/tmux-link-probe.test.js
 *
 * #1299: the exec-channel probe in native/lib/services/tmux_link_select.dart
 * finds OUR tmux client by SSH_CONNECTION (Tailscale SSH has no per-connection
 * sshd to walk to). This runs the REAL probe script, extracted from the Dart
 * source, against a private tmux server with two clients attached from
 * `script` under different SSH_CONNECTION values, under sh and busybox sh.
 * Skips LOUDLY when tmux or script is missing; never soft-passes.
 */

const { describe, it, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { spawn, spawnSync } = require('node:child_process');
const { mkdtempSync, readFileSync, rmSync } = require('node:fs');
const { resolve, join } = require('node:path');
const { tmpdir } = require('node:os');

const REPO_ROOT = resolve(__dirname, '../..');
const SRC = readFileSync(join(REPO_ROOT, 'native/lib/services/tmux_link_select.dart'), 'utf-8');

function probeScript() {
  const start = SRC.indexOf('const _probeScript = [');
  const end = SRC.indexOf('\n];', start);
  return SRC.slice(start, end)
    .split('\n')
    .map((l) => /^\s*r'(.*)',$/.exec(l))
    .filter(Boolean)
    .map((m) => m[1])
    .join(' ');
}

const have = (bin) => spawnSync('sh', ['-c', `command -v ${bin}`]).status === 0;
const missing = ['tmux', 'script'].filter((b) => !have(b));
if (missing.length) {
  console.warn(`SKIPPING tmux-link-probe tests: missing ${missing.join(', ')}`);
}

const CONN_A = '10.0.0.1 40001 10.0.0.2 22';
const CONN_B = '10.0.0.1 40002 10.0.0.2 22';

describe('tmux link probe script (#1299)', { skip: missing.length ? `missing ${missing.join(', ')}` : false }, () => {
  let dir, env, clients = [], ttyA, ttyB;

  const tmux = (...args) => spawnSync('tmux', args, { env, encoding: 'utf-8' });
  const attach = (conn) => {
    const c = spawn('script', ['-qfc', 'tmux attach', '/dev/null'], {
      env: { ...env, SSH_CONNECTION: conn },
      stdio: ['pipe', 'ignore', 'ignore'],
    });
    clients.push(c);
    return c;
  };
  const listClients = () =>
    tmux('list-clients', '-F', '#{client_tty} #{client_pid}').stdout.trim().split('\n').filter(Boolean);
  const ttyOfConn = (conn) => {
    for (const line of tmux('list-clients', '-F', '#{client_tty} #{client_pid}').stdout.trim().split('\n')) {
      const [tty, pid] = line.split(' ');
      const environ = readFileSync(`/proc/${pid}/environ`, 'latin1').split('\0');
      if (environ.includes(`SSH_CONNECTION=${conn}`)) return tty;
    }
    return null;
  };
  const probe = (shell, conn) => {
    const argv = shell === 'busybox' ? ['sh', '-c', probeScript()] : ['-c', probeScript()];
    const bin = shell === 'busybox' ? 'busybox' : 'sh';
    const e = { ...env };
    if (conn === undefined) delete e.SSH_CONNECTION;
    else e.SSH_CONNECTION = conn;
    const r = spawnSync(bin, argv, { env: e, encoding: 'utf-8' });
    assert.equal(r.status, 0, r.stderr);
    return r.stdout.split('\n').filter((l) => l.startsWith('M '));
  };

  before(async () => {
    dir = mkdtempSync(join(tmpdir(), 'tmux-probe-'));
    env = { ...process.env, TMUX_TMPDIR: dir, TERM: 'xterm' };
    delete env.TMUX;
    const r = tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'main', 'sleep 600');
    assert.equal(r.status, 0, r.stderr);
    attach(CONN_A);
    attach(CONN_B);
    for (let i = 0; i < 50 && listClients().length < 2; i++) await new Promise((r2) => setTimeout(r2, 100));
    assert.equal(listClients().length, 2, 'both clients attached');
    ttyA = ttyOfConn(CONN_A);
    ttyB = ttyOfConn(CONN_B);
    assert.ok(ttyA && ttyB && ttyA !== ttyB);
  });

  after(() => {
    for (const c of clients) c.kill();
    if (dir) {
      tmux('kill-server');
      rmSync(dir, { recursive: true, force: true });
    }
  });

  const shells = ['sh'];
  if (have('busybox')) shells.push('busybox');
  else console.warn('busybox not available: ash run of the probe skipped');

  for (const shell of shells) {
    describe(`under ${shell}`, () => {
      it('picks exactly the client sharing our SSH_CONNECTION (A)', () => {
        assert.deepEqual(probe(shell, CONN_A), [`M ${ttyA} main`]);
      });
      it('picks exactly the client sharing our SSH_CONNECTION (B)', () => {
        assert.deepEqual(probe(shell, CONN_B), [`M ${ttyB} main`]);
      });
      it('emits no M line when SSH_CONNECTION is unset or unknown', () => {
        assert.deepEqual(probe(shell, undefined), []);
        assert.deepEqual(probe(shell, '10.9.9.9 1 10.0.0.2 22'), []);
      });
      it('never prints the SSH_CONNECTION value', () => {
        const argv = shell === 'busybox' ? ['sh', '-c', probeScript()] : ['-c', probeScript()];
        const r = spawnSync(shell === 'busybox' ? 'busybox' : 'sh', argv, {
          env: { ...env, SSH_CONNECTION: CONN_A },
          encoding: 'utf-8',
        });
        assert.ok(!r.stdout.includes('40001') && !r.stdout.includes('10.0.0.1'));
      });
    });
  }
});
