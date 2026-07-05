#!/usr/bin/env bash
# scripts/native-connect-test.sh — On-emulator connect acceptance (#539 gate).
#
# Drives the real Flutter app on the emulator through an actual SSH connect to
# the test-sshd container, exercising the UI→foreground-task-isolate bootstrap
# that headless widget tests can't reach. This is the gate that catches the
# class of bug in #539 (connect deadlocks at State:idle).
#
# EMULATOR LOCATION (P0 infra move):
#   The emulator now runs in its OWN sibling container (mobissh-emulator) instead
#   of as a process inside fd-dev, so swiftshader crashes / zombie processes are
#   isolated (recovery = `docker restart mobissh-emulator`, no session loss).
#   This script defaults to that containerized emulator (EMU_CONTAINER=1).
#
#   ADB_MODE selects how fd-dev reaches the container's emulator:
#     connect (default) — fd-dev runs its OWN adb server and
#         `adb connect mobissh-emulator:5555`. This keeps `adb forward` LOCAL to
#         fd-dev, which flutter integration tests REQUIRE (flutter forwards the
#         Dart VM-service port then connects to 127.0.0.1:<port> on THIS host —
#         a remote adb server would bind that port in the emulator container,
#         unreachable from fd-dev). The test-sshd bridge + adb-reverse therefore
#         live on fd-dev (below), same as the legacy path.
#     remote — ANDROID_ADB_SERVER_SOCKET=tcp:mobissh-emulator:5037. flutter/adb
#         transparently use the container's adb server; the test-sshd bridge is
#         the socat INSIDE the container and `adb reverse` lands there. Good for
#         `adb devices` / install / `flutter devices`, but flutter integration
#         VM-service forwarding is NOT reachable from fd-dev (see above) — so the
#         end-to-end integration test uses `connect` mode.
#
#   EMU_CONTAINER=0 → legacy path: emulator as a process inside fd-dev via
#   emulator-ctl.sh (CPU-pinned). Kept for environments without the container.
#
# Network bridge (connect mode / legacy):
#   emulator 127.0.0.1:2222 --(adb reverse)--> fd-dev 127.0.0.1:2222
#                           --(socat)--------> test-sshd:22
#
# Requires: the `mobissh` docker network with test-sshd up, socat, adb, the
# Flutter SDK. Run from the repo root.
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
BRIDGE_PORT2="${BRIDGE_PORT2:-}"

# Emulator location + adb transport (see header).
EMU_CONTAINER="${EMU_CONTAINER:-1}"
ADB_MODE="${ADB_MODE:-connect}"
# The container exposes the guest adbd on 5556 (5555 is the emulator's own
# loopback bind and cannot be re-listened without colliding with it).
EMU_CONTAINER_NAME="${EMU_CONTAINER_NAME:-mobissh-emulator}"
EMU_ADBD_ENDPOINT="${EMU_ADBD_ENDPOINT:-${EMU_CONTAINER_NAME}:5556}"

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

# 1. Bring up the emulator (container or legacy) and resolve its adb device id.
if [[ "$EMU_CONTAINER" == "1" ]]; then
  log "using DEDICATED emulator container ($EMU_CONTAINER_NAME), ADB_MODE=$ADB_MODE"
  if ! "${REPO_ROOT}/scripts/emu-container-ctl.sh" ensure; then
    err "emu-container-ctl ensure failed — see: scripts/emu-container-ctl.sh logs"
    exit 2
  fi
  if [[ "$ADB_MODE" == "remote" ]]; then
    # flutter/adb talk to the container's adb server; the test-sshd bridge is the
    # socat INSIDE the container, so no fd-dev socat is started below.
    export ANDROID_ADB_SERVER_SOCKET="tcp:${EMU_CONTAINER_NAME}:5037"
    log "ANDROID_ADB_SERVER_SOCKET=$ANDROID_ADB_SERVER_SOCKET"
    adb wait-for-device 2>/dev/null || true
    DEVICE="$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
  else
    # connect mode: fd-dev's own adb server connects to the exposed guest adbd.
    log "adb connect ${EMU_ADBD_ENDPOINT}"
    secs=0
    DEVICE=""
    while (( secs < 60 )); do
      adb connect "$EMU_ADBD_ENDPOINT" 2>/dev/null || true
      if adb -s "$EMU_ADBD_ENDPOINT" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' | grep -q 1; then
        DEVICE="$EMU_ADBD_ENDPOINT"
        break
      fi
      sleep 2; secs=$((secs + 2))
    done
  fi
  if [[ -z "${DEVICE:-}" ]]; then
    err "no online device from emulator container (mode=$ADB_MODE)"
    err "diagnostics: scripts/emu-container-ctl.sh status ; scripts/emu-container-ctl.sh logs"
    exit 2
  fi
else
  # Legacy: emulator as a process inside fd-dev, CPU-pinned. emulator-ctl.sh
  # boots iff needed and reuses a live one; emulator-maintain keeps /data healthy.
  log "using LEGACY in-fd-dev emulator (EMU_CONTAINER=0)"
  if ! "${REPO_ROOT}/scripts/emulator-ctl.sh" ensure; then
    err "emulator-ctl ensure failed — see /tmp/mobissh/logs/emulator-detached.log"
    exit 2
  fi
  DEVICE="$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
  if [[ -z "$DEVICE" ]]; then
    err "no online adb device after emulator-ctl ensure"
    exit 2
  fi
  if ! "${REPO_ROOT}/scripts/emulator-maintain.sh" ensure-healthy; then
    err "emulator-maintain reported low storage it could not recover — install may fail"
  fi
  DEVICE="$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
  if [[ -z "$DEVICE" ]]; then
    err "no online adb device after emulator-maintain"
    exit 2
  fi
fi
log "device: $DEVICE"

# 2. Verify test-sshd reachable from this container.
if ! getent hosts "$SSHD_HOST" >/dev/null 2>&1; then
  err "$SSHD_HOST not resolvable — is the mobissh docker network joined + test-sshd up?"
  err "try: docker compose -f docker-compose.test.yml up -d"
  exit 2
fi
log "$SSHD_HOST resolves OK"

# 3./4. Bridge + reverse. In `remote` mode the container's own socat already
#       bridges 2222→test-sshd and `adb reverse` lands there, so we skip the
#       fd-dev socat. In connect/legacy mode the reverse binds on fd-dev, so we
#       start the fd-dev socat and reverse here.
if [[ "$EMU_CONTAINER" == "1" && "$ADB_MODE" == "remote" ]]; then
  log "remote adb mode: test-sshd bridge is the container's socat; adb reverse tcp:${BRIDGE_PORT}"
  adb -s "$DEVICE" reverse "tcp:${BRIDGE_PORT}" "tcp:${BRIDGE_PORT}"
  if [[ -n "$BRIDGE_PORT2" ]]; then
    adb -s "$DEVICE" reverse "tcp:${BRIDGE_PORT2}" "tcp:${BRIDGE_PORT}"
  fi
else
  log "starting socat 127.0.0.1:${BRIDGE_PORT} → ${SSHD_HOST}:${SSHD_PORT}"
  socat "TCP-LISTEN:${BRIDGE_PORT},fork,reuseaddr,bind=127.0.0.1" "TCP:${SSHD_HOST}:${SSHD_PORT}" &
  echo $! > "$PROXY_PID_FILE"
  sleep 1
  log "adb reverse tcp:${BRIDGE_PORT}"
  adb -s "$DEVICE" reverse "tcp:${BRIDGE_PORT}" "tcp:${BRIDGE_PORT}"

  # Optional second bridge (same test-sshd, different loopback port) so a second
  # distinct host:port:username session is reachable on-device.
  if [[ -n "$BRIDGE_PORT2" ]]; then
    log "starting socat 127.0.0.1:${BRIDGE_PORT2} → ${SSHD_HOST}:${SSHD_PORT}"
    socat "TCP-LISTEN:${BRIDGE_PORT2},fork,reuseaddr,bind=127.0.0.1" "TCP:${SSHD_HOST}:${SSHD_PORT}" &
    echo $! > "$PROXY2_PID_FILE"
    sleep 1
    log "adb reverse tcp:${BRIDGE_PORT2}"
    adb -s "$DEVICE" reverse "tcp:${BRIDGE_PORT2}" "tcp:${BRIDGE_PORT2}"
  fi
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
#    APK carrying the integration driver and runs the test, which fills the form
#    (127.0.0.1:2222 / testuser / testpass), taps Connect, accepts the host key,
#    and asserts the terminal screen mounts.
# The BUILD runs in fd-dev. Pin it to the BUILD cores + nice/ionice so, even
# though the emulator now lives in its own container, a build spike still yields
# CPU/IO (belt-and-suspenders; the container's KVM guest is already isolated).
BUILD_CORES="${BUILD_CORES:-4-11}"
TASKSET=()
if command -v ionice >/dev/null 2>&1; then TASKSET+=(ionice -c 3); fi
TASKSET+=(nice -n 15)
if command -v taskset >/dev/null 2>&1; then TASKSET+=(taskset -c "$BUILD_CORES"); fi
log "running integration test on device ($TEST_FILE) on cores $BUILD_CORES (builds + installs)..."
if "${TASKSET[@]}" "${REPO_ROOT}/scripts/flutter-cmd.sh" --in "$NATIVE_DIR" test \
    "$TEST_FILE" -d "$DEVICE"; then
  echo "+ TEST PASSED — $TEST_FILE"
  exit 0
else
  echo "! TEST FAILED — $TEST_FILE (see #539 deadlock signature if connect)"
  exit 1
fi
