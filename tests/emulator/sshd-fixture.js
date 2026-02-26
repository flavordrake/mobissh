/**
 * tests/emulator/sshd-fixture.js
 *
 * Docker test-sshd lifecycle helper. Starts the Alpine+OpenSSH container
 * from docker-compose.test.yml and waits for SSH to be ready.
 */

const { execSync } = require('child_process');
const net = require('net');

const SSHD_PORT = Number(process.env.SSHD_PORT || 2222);
const SSHD_HOST = process.env.SSHD_HOST || 'localhost';

const TEST_USER = 'testuser';
const TEST_PASS = 'testpass';

/**
 * Start the test-sshd Docker container (idempotent) and wait for port readiness.
 */
function ensureTestSshd() {
  execSync(
    'docker compose -f docker-compose.test.yml up -d test-sshd',
    { cwd: process.cwd(), encoding: 'utf8', timeout: 60_000 }
  );

  // Wait for SSH to accept connections
  for (let i = 0; i < 30; i++) {
    if (_portOpen(SSHD_HOST, SSHD_PORT)) return;
    execSync('sleep 0.5');
  }
  throw new Error(`test-sshd not ready on ${SSHD_HOST}:${SSHD_PORT} after 15s`);
}

function _portOpen(host, port) {
  try {
    const sock = new net.Socket();
    sock.setTimeout(1000);
    const result = new Promise((resolve) => {
      sock.on('connect', () => { sock.destroy(); resolve(true); });
      sock.on('error', () => { sock.destroy(); resolve(false); });
      sock.on('timeout', () => { sock.destroy(); resolve(false); });
      sock.connect(port, host);
    });
    // execSync context — use a synchronous TCP check instead
    execSync(`bash -c 'echo > /dev/tcp/${host}/${port}'`, { timeout: 1000 });
    return true;
  } catch {
    return false;
  }
}

module.exports = { ensureTestSshd, SSHD_HOST, SSHD_PORT, TEST_USER, TEST_PASS };
