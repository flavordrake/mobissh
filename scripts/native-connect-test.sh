#!/usr/bin/env bash
# scripts/native-connect-test.sh — On-emulator connect acceptance (#539 gate).
#
# Drives the real Flutter app on the emulator through an actual SSH connect to
# the test-sshd container, exercising the UI→foreground-task-isolate bootstrap
# that headless widget tests can't reach. This is the gate that catches the
# class of bug in #539 (connect deadlocks at State:idle).
#
# Network bridge:
#   emulator 127.0.0.1:2222 --(adb reverse)--> fd-dev 127.0.0.1:2222
#                           --(socat)--------> test-sshd:22
#
# Requires: a booted emulator, the `mobissh` docker network with test-sshd up,
# socat, the Flutter SDK. Run from the repo root.
#
# Exit 0 = connect reached `connected`. Exit 1 = deadlock / failure. Exit 2 = setup error.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"
LOGFILE="${MOBISSH_LOGDIR}/native-connect-test.log"
exec > >(tee -a "$LOGFILE") 2>&1

# Which integration test to run. Defaults to the connect smoke (#539 gate);
# pass a path (relative to native/) as $1 to run a different one over the same
# socat+adb-reverse bridge. The test-port epic (#548) reuses this harness.
TEST_FILE="${1:-integration_test/connect_smoke_test.dart}"

NATIVE_DIR="${REPO_ROOT}/native"
PROXY_PID_FILE="${MOBISSH_TMPDIR}/connect-test-socat.pid"
PROXY2_PID_FILE="${MOBISSH_TMPDIR}/connect-test-socat2.pid"
SSHD_HOST="test-sshd"
SSHD_PORT="22"
BRIDGE_PORT="2222"
# Optional second bridge port → same test-sshd. When set, the emulator can
# reach a SECOND distinct host:port:username tuple (127.0.0.1:$BRIDGE_PORT2),
# which the multi-session lifecycle test needs to create two real sessions
# without a second sshd container. Off by default so the connect smoke is
# unaffected.
BRIDGE_PORT2="${BRIDGE_PORT2:-}"

log() { echo "> $*"; }
err() { echo "! $*" >&2; }

cleanup() {
  # Tear down the socat proxy + adb reverse so repeated runs don't stack.
  if [[ -f "$PROXY_PID_FILE" ]]; then
    local pid
    pid="$(cat "$PROXY_PID_FILE")"
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$PROXY_PID_FILE"
  fi
  if [[ -f "$PROXY2_PID_FILE" ]]; then
    local pid2
    pid2="$(cat "$PROXY2_PID_FILE")"
    if kill -0 "$pid2" 2>/dev/null; then
      kill "$pid2" 2>/dev/null || true
    fi
    rm -f "$PROXY2_PID_FILE"
  fi
  if [[ -n "${GRANT_WATCHER_PID:-}" ]] && kill -0 "$GRANT_WATCHER_PID" 2>/dev/null; then
    kill "$GRANT_WATCHER_PID" 2>/dev/null || true
  fi
  if [[ -n "${DEVICE:-}" ]]; then
    adb -s "$DEVICE" reverse --remove "tcp:${BRIDGE_PORT}" 2>/dev/null || true
    if [[ -n "$BRIDGE_PORT2" ]]; then
      adb -s "$DEVICE" reverse --remove "tcp:${BRIDGE_PORT2}" 2>/dev/null || true
    fi
  fi
}
GRANT_WATCHER_PID=""
trap cleanup EXIT

# 1. Resolve device.
DEVICE="$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
if [[ -z "$DEVICE" ]]; then
  err "no online adb device — boot an emulator first"
  exit 2
fi
log "device: $DEVICE"

# 2. Verify test-sshd reachable from this container.
if ! getent hosts "$SSHD_HOST" >/dev/null 2>&1; then
  err "$SSHD_HOST not resolvable — is the mobissh docker network joined + test-sshd up?"
  err "try: docker compose -f docker-compose.test.yml up -d"
  exit 2
fi
log "$SSHD_HOST resolves OK"

# 3. socat proxy: fd-dev 127.0.0.1:$BRIDGE_PORT → test-sshd:22.
#    (adb reverse can only target the adb-server host's loopback, and
#    test-sshd is a sibling container not on loopback — so we bounce through
#    socat.)
log "starting socat 127.0.0.1:${BRIDGE_PORT} → ${SSHD_HOST}:${SSHD_PORT}"
socat "TCP-LISTEN:${BRIDGE_PORT},fork,reuseaddr,bind=127.0.0.1" "TCP:${SSHD_HOST}:${SSHD_PORT}" &
echo $! > "$PROXY_PID_FILE"
sleep 1

# 4. adb reverse: emulator 127.0.0.1:$BRIDGE_PORT → fd-dev 127.0.0.1:$BRIDGE_PORT.
log "adb reverse tcp:${BRIDGE_PORT}"
adb -s "$DEVICE" reverse "tcp:${BRIDGE_PORT}" "tcp:${BRIDGE_PORT}"

# 3b/4b. Optional second bridge (same test-sshd, different loopback port) so a
#        second distinct host:port:username session is reachable on-device.
if [[ -n "$BRIDGE_PORT2" ]]; then
  log "starting socat 127.0.0.1:${BRIDGE_PORT2} → ${SSHD_HOST}:${SSHD_PORT}"
  socat "TCP-LISTEN:${BRIDGE_PORT2},fork,reuseaddr,bind=127.0.0.1" "TCP:${SSHD_HOST}:${SSHD_PORT}" &
  echo $! > "$PROXY2_PID_FILE"
  sleep 1
  log "adb reverse tcp:${BRIDGE_PORT2}"
  adb -s "$DEVICE" reverse "tcp:${BRIDGE_PORT2}" "tcp:${BRIDGE_PORT2}"
fi

# 4b. POST_NOTIFICATIONS grant-watcher. The app requests this at first
#     foreground-service start (real users tap Allow), but the integration
#     test can't tap a system permission dialog. The app's code checks
#     `checkNotificationPermission()` first, so pre-granting makes the request
#     a no-op. The test reinstalls the app itself, so we grant in a loop until
#     the test process exits — catching the post-install window before the
#     test taps Connect.
log "starting POST_NOTIFICATIONS grant-watcher"
(
  while true; do
    adb -s "$DEVICE" shell pm grant com.flavordrake.mobissh android.permission.POST_NOTIFICATIONS 2>/dev/null || true
    sleep 1
  done
) &
GRANT_WATCHER_PID=$!

# 5. Run the integration test on the device. This builds + installs a debug
#    APK carrying the integration driver and runs connect_smoke_test.dart,
#    which fills the form (127.0.0.1:2222 / testuser / testpass), taps Connect,
#    accepts the host key, and asserts the terminal screen mounts.
log "running integration test on device ($TEST_FILE) (this builds + installs)..."
if "${REPO_ROOT}/scripts/flutter-cmd.sh" --in "$NATIVE_DIR" test \
    "$TEST_FILE" -d "$DEVICE"; then
  echo "+ TEST PASSED — $TEST_FILE"
  exit 0
else
  echo "! TEST FAILED — $TEST_FILE (see #539 deadlock signature if connect)"
  exit 1
fi
