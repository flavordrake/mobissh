/**
 * tests/emulator/sshd-fixture.js
 *
 * Docker test-sshd lifecycle helper. Starts the Alpine+OpenSSH container
 * from docker-compose.test.yml and waits for SSH to be ready.
 */

const { execSync } = require('child_process');
const path = require('path');
const fs = require('fs');

// Sibling Docker containers use Docker DNS (test-sshd:22).
// Env vars override for non-Docker environments.
const SSHD_PORT = Number(process.env.SSHD_PORT || 22);
const SSHD_HOST = process.env.SSHD_HOST || 'test-sshd';
const NETWORK_NAME = 'mobissh';

const TEST_USER = 'testuser';
const TEST_PASS = 'testpass';

// Private key path — copied with safe permissions for SSH client
const _KEY_SRC = path.resolve(__dirname, '../../docker/test-sshd/testuser_id_ed25519');
const TEST_KEY_PATH = '/tmp/mobissh-test-sshd-key';

/**
 * Start the test-sshd Docker container (idempotent), join the shared network,
 * and wait for SSH readiness via Docker DNS.
 */
function ensureTestSshd() {
  // Ensure shared Docker network exists, then start container
  try { execSync(`docker network create ${NETWORK_NAME}`, { timeout: 10_000 }); } catch { /* exists */ }
  execSync(
    'docker compose -f docker-compose.test.yml up -d test-sshd',
    { cwd: process.cwd(), encoding: 'utf8', timeout: 60_000 }
  );

  // Join this container to the shared network (idempotent)
  try {
    const hostname = execSync('hostname', { encoding: 'utf8' }).trim();
    execSync(`docker network connect ${NETWORK_NAME} ${hostname}`, {
      encoding: 'utf8', timeout: 10_000
    });
  } catch { /* already connected */ }

  // Copy private key with safe permissions
  fs.copyFileSync(_KEY_SRC, TEST_KEY_PATH);
  fs.chmodSync(TEST_KEY_PATH, 0o600);

  // Wait for SSH to accept connections via Docker DNS
  for (let i = 0; i < 30; i++) {
    if (_portOpen(SSHD_HOST, SSHD_PORT)) return;
    execSync('sleep 0.5');
  }
  throw new Error(`test-sshd not ready on ${SSHD_HOST}:${SSHD_PORT} after 15s`);
}

function _portOpen(host, port) {
  try {
    execSync(`bash -c 'echo > /dev/tcp/${host}/${port}'`, { timeout: 1000 });
    return true;
  } catch {
    return false;
  }
}

module.exports = { ensureTestSshd, SSHD_HOST, SSHD_PORT, TEST_USER, TEST_PASS, TEST_KEY_PATH };
