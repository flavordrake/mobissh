#!/usr/bin/env bash
# scripts/run-kbrace-repro.sh — run the #975 keyboard-race tmux-tap repro with a
# STRETCHED soft-keyboard slide so the mid-animation window is wide enough to tap.
#
# Sets the emulator's animation scales to $1 (default 5 → ~1s slide), runs the
# kbrace integration test over the standard native-connect-test bridge, then
# resets the scales to 1.0. The container entrypoint sets 1.0 at boot; this only
# needs to widen it for the duration of the run.
#
# Usage: scripts/run-kbrace-repro.sh [scale]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"
LOGFILE="${MOBISSH_LOGDIR}/kbrace-repro.log"
exec > >(tee -a "$LOGFILE") 2>&1

SCALE="${1:-5}"
EMU_CONTAINER_NAME="${EMU_CONTAINER_NAME:-mobissh-emulator}"
EMU_ADBD_ENDPOINT="${EMU_ADBD_ENDPOINT:-${EMU_CONTAINER_NAME}:5556}"
TEST_FILE="integration_test/tmux_status_tap_kbrace_test.dart"

log() { echo "> $*"; }

log "ensuring emulator container is up"
"${REPO_ROOT}/scripts/emu-container-ctl.sh" ensure

log "adb connect ${EMU_ADBD_ENDPOINT}"
adb connect "$EMU_ADBD_ENDPOINT" || true

set_scales() {
  local v="$1"
  adb -s "$EMU_ADBD_ENDPOINT" shell settings put global animator_duration_scale "$v" || true
  adb -s "$EMU_ADBD_ENDPOINT" shell settings put global transition_animation_scale "$v" || true
  adb -s "$EMU_ADBD_ENDPOINT" shell settings put global window_animation_scale "$v" || true
}

reset_scales() {
  log "resetting animation scales to 1.0"
  set_scales 1.0
}
trap reset_scales EXIT

log "setting animation scales to ${SCALE}"
set_scales "$SCALE"
adb -s "$EMU_ADBD_ENDPOINT" shell settings get global animator_duration_scale || true

log "running ${TEST_FILE}"
"${REPO_ROOT}/scripts/native-connect-test.sh" "$TEST_FILE"
