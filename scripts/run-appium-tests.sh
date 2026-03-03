#!/usr/bin/env bash
# scripts/run-appium-tests.sh
#
# Full setup/run/teardown for Appium-based Android emulator tests.
# Handles: server, Docker sshd, emulator boot, ADB forwarding, Appium server,
# screen recording with debug overlays, Playwright test runner, artifact collection.
#
# Usage:
#   scripts/run-appium-tests.sh                            # all Appium tests
#   scripts/run-appium-tests.sh gesture-scroll-baseline    # specific test file
#   scripts/run-appium-tests.sh --suite baseline-pre       # all tests, suite-tagged archive
#   scripts/run-appium-tests.sh integrate-117 --suite integrate-117-before
# Log: /tmp/run-appium-tests.log

set -euo pipefail

RUN_LOG="/tmp/run-appium-tests.log"
exec > >(tee -a "$RUN_LOG") 2>&1
echo "$(date '+%Y-%m-%d %H:%M:%S') run-appium-tests.sh started"

ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"

AVD_NAME="MobiSSH_Pixel7"
MOBISSH_PORT="${MOBISSH_PORT:-8081}"
APPIUM_PORT="${APPIUM_PORT:-4723}"
SPEC=""
SUITE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --suite) SUITE="$2"; shift 2 ;;
    *) SPEC="$1"; shift ;;
  esac
done
RESULTS_DIR="test-results-appium"
# Record to /tmp first — Playwright cleans RESULTS_DIR at startup, which would
# delete a recording in progress. Move the finalized file in afterward.
RECORDING_TMP="/tmp/mobissh-appium-recording.webm"

log() { echo "> $*"; }
ok()  { echo "+ $*"; }
err() { echo "! $*" >&2; exit 1; }

# Run an ADB command, log failures but don't abort the script.
# ADB setup commands are best-effort — the emulator may not have Chrome yet,
# permissions may already be granted, etc.
adb_try() {
  if ! adb "$@" 2>&1; then
    log "adb $1 $2 ... failed (non-fatal)"
  fi
}

wait_for_port() {
  local host=$1 port=$2 label=$3 max=${4:-30}
  for i in $(seq 1 "$max"); do
    if bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null; then
      ok "$label ready on port $port"
      return 0
    fi
    sleep 0.5
  done
  err "$label not ready on port $port after $((max / 2))s"
}

# Phase 1: Infrastructure
log "Phase 1: Infrastructure"
PORT=$MOBISSH_PORT scripts/server-ctl.sh ensure
docker compose -f docker-compose.test.yml up -d test-sshd 2>&1
wait_for_port localhost 2222 "test-sshd" 20

# Phase 2: Emulator
log "Phase 2: Android emulator"
command -v emulator &>/dev/null || err "emulator not found. Run scripts/setup-avd.sh"
command -v adb &>/dev/null || err "adb not found. Run scripts/setup-avd.sh"

if ! adb devices 2>/dev/null | grep -q 'emulator\|device$'; then
  log "Booting emulator ($AVD_NAME)..."
  sg kvm -c "emulator -avd \"$AVD_NAME\" -no-snapshot-save -gpu auto -no-audio" &
  EMU_PID=$!
  adb wait-for-device
  for i in $(seq 1 120); do
    if adb shell getprop sys.boot_completed 2>/dev/null | grep -q '^1$'; then break; fi
    if (( i == 120 )); then err "Emulator failed to boot within 120s"; fi
    sleep 1
  done
  ok "Emulator booted (PID $EMU_PID)"
else
  ok "Emulator already running"
fi

# Phase 3: ADB setup + debug visualizations
log "Phase 3: ADB setup and debug overlays"
adb_try reverse tcp:"$MOBISSH_PORT" tcp:"$MOBISSH_PORT"

# Enable BOTH touch debug overlays for video evidence
# show_touches: green circles at touch points
# pointer_location: crosshair + coordinate readout at screen top
adb_try shell settings put system show_touches 1
adb_try shell settings put system pointer_location 1
ok "Debug visualizations enabled (show_touches + pointer_location)"

# Chrome flags for unattended testing
adb_try shell pm grant com.android.chrome android.permission.POST_NOTIFICATIONS
adb_try shell "echo '_ --disable-fre --no-first-run --no-default-browser-check --disable-features=FeatureEngagementTracker' > /data/local/tmp/chrome-command-line"

# Phase 4: Appium server
log "Phase 4: Appium server"
scripts/start-appium.sh ensure
wait_for_port localhost "$APPIUM_PORT" "Appium" 20

# Phase 5: Screen recording + tests
log "Phase 5: Running tests"
mkdir -p "$RESULTS_DIR"

rm -f "$RECORDING_TMP"
adb emu screenrecord start "$RECORDING_TMP"

EXTRA_ARGS=()
[[ -n "$SPEC" ]] && EXTRA_ARGS+=("tests/appium/${SPEC}.spec.js")

set +e
BASE_URL="http://localhost:$MOBISSH_PORT" \
  APPIUM_PORT="$APPIUM_PORT" \
  npx playwright test \
    --config=playwright.appium.config.js \
    "${EXTRA_ARGS[@]}"
EXIT=$?
set -e

# Stop recording cleanly via emulator console command.
# Unlike adb shell screenrecord (which requires SIGINT to write the moov atom),
# the emulator console command finalizes the webm container automatically.
adb emu screenrecord stop

# Phase 6: Validate recording
log "Phase 6: Validating artifacts"
RECORDING_FILE="$RESULTS_DIR/recording.webm"
mkdir -p "$RESULTS_DIR"
if [[ -f "$RECORDING_TMP" ]]; then
  mv "$RECORDING_TMP" "$RECORDING_FILE"
  SIZE=$(du -h "$RECORDING_FILE" | cut -f1)
  ok "Recording: $RECORDING_FILE ($SIZE)"
  if command -v ffprobe &>/dev/null; then
    PROBE_OUTPUT=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$RECORDING_FILE" 2>&1)
    PROBE_EXIT=$?
    if [[ $PROBE_EXIT -eq 0 && -n "$PROBE_OUTPUT" && "$PROBE_OUTPUT" != "N/A" ]]; then
      ok "Recording validated: ${PROBE_OUTPUT}s, container intact"
    else
      log "WARNING: recording may be corrupted (ffprobe exit=$PROBE_EXIT output=$PROBE_OUTPUT)"
    fi
  else
    log "WARNING: ffprobe not installed, cannot validate recording. Run scripts/setup-appium.sh"
  fi
else
  log "WARNING: recording not found at $RECORDING_TMP"
fi

# Phase 7: Archive to persistent git-committed history
# test-history/ is tracked in git for historical regression comparison.
# Playwright never touches this directory.
TIMESTAMP=$(date +%Y%m%dT%H%M%S%z)
SUITE_SUFFIX="${SUITE:+-$SUITE}"
HISTORY_DIR="test-history/appium/${TIMESTAMP}${SUITE_SUFFIX}"
log "Phase 7: Archiving to $HISTORY_DIR"
mkdir -p "$HISTORY_DIR"

# Copy recording
if [[ -f "$RECORDING_FILE" ]]; then
  cp "$RECORDING_FILE" "$HISTORY_DIR/recording.webm"
fi

# Copy HTML report (self-contained: index.html + data/)
if [[ -d "playwright-report-appium" ]]; then
  cp -r playwright-report-appium "$HISTORY_DIR/report"
fi

# Write run metadata
cat > "$HISTORY_DIR/run-info.txt" <<RUNEOF
timestamp: $TIMESTAMP
git_hash: $(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
test_spec: ${SPEC:-all}
suite: ${SUITE:-default}
exit_code: $EXIT
RUNEOF
ok "Archived to $HISTORY_DIR"

# Disable pointer_location after test (distracting for normal use)
adb_try shell settings put system pointer_location 0

log "Tests finished (exit $EXIT)"
log "HTML report: playwright-report-appium/"
log "Recording: $RECORDING_FILE"
log "History: $HISTORY_DIR"
echo "$(date '+%Y-%m-%d %H:%M:%S') run-appium-tests.sh finished (exit $EXIT)"
log "Log saved to: $RUN_LOG"
exit "$EXIT"
