/**
 * test/infra/integration-device-lost.test.js
 *
 * On 2026-10-05 the fleet emulator went `offline` mid-suite. The runner kept
 * going: every remaining test failed in seconds with "no online device", which
 * read as dozens of regressions, and the run held the shared lease for over an hour
 * on a dead device. The runners now check the device after a failure, through
 * integration_device_online in scripts/lib/integration-fixtures.sh, and stop
 * with "NOT VALIDATED" so the lease is released.
 */

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const { mkdtempSync, writeFileSync, chmodSync, readFileSync, existsSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { join, resolve } = require('node:path');

const LIB = resolve(__dirname, '../../scripts/lib/integration-fixtures.sh');
const SUITE = resolve(__dirname, '../../scripts/native-integration-suite.sh');
const SUBSET = resolve(__dirname, '../../scripts/integration-subset.sh');

// A fake `adb` whose device comes online on probe number $FAKE_ONLINE_AT
// (0 = never). Each `getprop`/`get-state` call counts as one probe.
function fakeAdb() {
  const dir = mkdtempSync(join(tmpdir(), 'fake-adb-'));
  const counter = join(dir, 'probes');
  writeFileSync(counter, '0');
  writeFileSync(join(dir, 'adb'), `#!/usr/bin/env bash
case "$*" in
  *getprop*|*get-state*)
    n=$(( $(cat "${counter}") + 1 )); echo "$n" > "${counter}"
    if [[ "\${FAKE_ONLINE_AT:-0}" != 0 && "$n" -ge "\${FAKE_ONLINE_AT}" ]]; then
      case "$*" in *getprop*) echo 1 ;; *) echo device ;; esac
      exit 0
    fi
    echo "error: device offline" >&2; exit 1 ;;
  *) exit 0 ;;
esac
`);
  chmodSync(join(dir, 'adb'), 0o755);
  return { dir, probes: () => Number(readFileSync(counter, 'utf-8').trim()) };
}

function online(onlineAt, mode) {
  const adb = fakeAdb();
  const r = spawnSync('bash', ['-c', `source "${LIB}"; integration_device_online`], {
    encoding: 'utf-8',
    env: {
      ...process.env,
      PATH: `${adb.dir}:${process.env.PATH}`,
      FAKE_ONLINE_AT: String(onlineAt),
      ADB_MODE: mode,
      EMU_ADBD_ENDPOINT: 'emu.test:5556',
      INTEGRATION_DEVICE_PROBES: '3',
      INTEGRATION_DEVICE_PROBE_SLEEP: '0',
    },
  });
  return { ok: r.status === 0, probes: adb.probes(), stderr: r.stderr };
}

describe('integration_device_online', () => {
  it('is online when the device answers (connect mode)', () => {
    assert.equal(online(1, 'connect').ok, true);
  });

  it('is online when the device answers (local adb server)', () => {
    assert.equal(online(1, 'server').ok, true);
  });

  it('rides out a brief blip within the probe budget', () => {
    const r = online(3, 'connect');
    assert.equal(r.ok, true);
    assert.equal(r.probes, 3);
  });

  it('reports LOST when the device never comes back, after a bounded number of probes', () => {
    const r = online(0, 'connect');
    assert.equal(r.ok, false);
    assert.equal(r.probes, 3, 'bounded: does not wait forever');
  });
});

describe('runners stop on device loss instead of failing every remaining test', () => {
  for (const [name, path] of [['suite', SUITE], ['subset', SUBSET]]) {
    it(`${name}: checks the device after a failure and exits NOT VALIDATED`, () => {
      assert.ok(existsSync(path));
      const src = readFileSync(path, 'utf-8');
      assert.match(src, /integration_device_online/, 'probes the device after a failed test');
      assert.match(src, /NOT VALIDATED/, 'says the run proves nothing');
      assert.match(src, /exit 3/, 'a distinct exit code for device loss');
    });
  }
});
