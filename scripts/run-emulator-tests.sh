#!/usr/bin/env bash
# scripts/run-emulator-tests.sh
#
# Full setup/run/teardown for Android emulator tests.
# Handles: server, Docker sshd, emulator boot, ADB forwarding, Chrome CDP, Playwright.
#
# Usage:
#   bash scripts/run-emulator-tests.sh              # run all emulator tests
#   bash scripts/run-emulator-tests.sh smoke.spec.js # run specific test file

set -euo pipefail

ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"

AVD_NAME="MobiSSH_Pixel7"
MOBISSH_PORT="${MOBISSH_PORT:-8081}"
CDP_PORT="${CDP_PORT:-9222}"
SPEC="${1:-}"
RESULTS_DIR="test-results/emulator"
RECORDING_PATH="/sdcard/emulator-test.mp4"

log() { echo "> $*"; }
ok()  { echo "+ $*"; }
err() { echo "! $*" >&2; exit 1; }

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
log "Phase 1: Infrastructure setup"

# 1a. MobiSSH server — healthy at HEAD
log "Ensuring MobiSSH server..."
PORT=$MOBISSH_PORT bash scripts/server-ctl.sh ensure

# 1b. Docker test-sshd — for real SSH integration tests
log "Ensuring Docker test-sshd..."
docker compose -f docker-compose.test.yml up -d test-sshd 2>&1 | grep -v '^$' || true
wait_for_port localhost 2222 "test-sshd" 20

# Phase 2: Emulator
log "Phase 2: Android emulator"

command -v emulator &>/dev/null || err "emulator not found. Run: bash scripts/setup-avd.sh"
command -v adb &>/dev/null || err "adb not found. Run: bash scripts/setup-avd.sh"

if ! adb devices 2>/dev/null | grep -q 'emulator\|device$'; then
  log "No device detected. Booting emulator ($AVD_NAME)..."
  sg kvm -c "emulator -avd \"$AVD_NAME\" -no-snapshot-save -gpu auto -no-audio" &
  EMU_PID=$!

  adb wait-for-device
  for i in $(seq 1 120); do
    if adb shell getprop sys.boot_completed 2>/dev/null | grep -q '^1$'; then
      break
    fi
    if (( i == 120 )); then err "Emulator failed to boot within 120s"; fi
    sleep 1
  done
  ok "Emulator booted (PID $EMU_PID)"
else
  ok "Emulator already running"
fi

# Dismiss Chrome nag modals (first-run, notifications promo, etc.) using UI automation.
# Dumps the screen UI hierarchy and taps the first known dismiss button found.
# Called once after Chrome starts, before Playwright tests run.
dismiss_chrome_modals() {
  local dump_remote="/sdcard/mobissh_ui_dump.xml"
  local dump_local="/tmp/mobissh_ui_dump.xml"
  local dismiss_labels=("No thanks" "Skip" "Got it" "Dismiss" "Not now" "No Thanks")

  adb shell "uiautomator dump $dump_remote" 2>/dev/null || return 0
  adb pull "$dump_remote" "$dump_local" 2>/dev/null || return 0

  for label in "${dismiss_labels[@]}"; do
    local line bounds x1 y1 x2 y2 cx cy
    line=$(grep "text=\"$label\"" "$dump_local" 2>/dev/null | head -1 || true)
    [[ -z "$line" ]] && continue

    bounds=$(echo "$line" | sed -n 's/.*bounds="\([^"]*\)".*/\1/p')
    [[ -z "$bounds" ]] && continue

    x1=$(echo "$bounds" | sed 's/\[\([0-9]*\),.*/\1/')
    y1=$(echo "$bounds" | sed 's/\[[0-9]*,\([0-9]*\)\]\[.*/\1/')
    x2=$(echo "$bounds" | sed 's/.*\]\[\([0-9]*\),.*/\1/')
    y2=$(echo "$bounds" | sed 's/.*,\([0-9]*\)\]$/\1/')
    cx=$(( (x1 + x2) / 2 ))
    cy=$(( (y1 + y2) / 2 ))

    log "Dismissing Chrome modal: tapping '$label' at ($cx, $cy)"
    adb shell input tap "$cx" "$cy" 2>/dev/null || true
    sleep 0.5
    return 0
  done
  # No modals found — that's fine
  return 0
}

# Phase 3: ADB forwarding + Chrome CDP
log "Phase 3: ADB forwarding and Chrome CDP"

adb reverse tcp:"$MOBISSH_PORT" tcp:"$MOBISSH_PORT" 2>/dev/null || true
adb forward tcp:"$CDP_PORT" localabstract:chrome_devtools_remote 2>/dev/null || true
ok "Port forwarding configured (server :$MOBISSH_PORT, CDP :$CDP_PORT)"

# Enable Chrome remote debugging (Play Store Chrome needs set-debug-app to
# expose the DevTools Unix socket)
adb shell am set-debug-app --persistent com.android.chrome 2>/dev/null || true

# Pre-grant notification permission so Chrome never shows the nag modal (#141).
# On API 33+ (Android 13), POST_NOTIFICATIONS is a runtime permission — if not
# granted, Chrome shows a full-screen "Turn on notifications" dialog on first use.
adb shell pm grant com.android.chrome android.permission.POST_NOTIFICATIONS 2>/dev/null || true

# Suppress Chrome first-run experience, default-browser check, and in-product
# help via command-line flags. The file must start with an underscore (Chrome convention).
# --disable-features=FeatureEngagementTracker disables the IPH system that
# drives the "Chrome notifications make things easier" modal (#141).
adb shell "echo '_ --disable-fre --no-first-run --no-default-browser-check --disable-features=FeatureEngagementTracker' > /data/local/tmp/chrome-command-line" 2>/dev/null || true

# Enable "Show taps" for real taps (ADB/finger). CDP touches use an in-page
# touch visualizer instead (pointer_location doesn't work with CDP).
adb shell settings put system show_touches 1 2>/dev/null || true
adb shell settings put system pointer_location 0 2>/dev/null || true

# Check if Chrome is responding to CDP already
if ! curl -sf "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null 2>&1; then
  log "Chrome not responding to CDP, restarting..."
  adb shell am force-stop com.android.chrome 2>/dev/null || true
  sleep 1
  adb shell am start -n com.android.chrome/com.google.android.apps.chrome.Main \
    -a android.intent.action.VIEW -d 'about:blank' 2>/dev/null || true

  # Wait for CDP socket to come alive (Chrome needs a moment after launch)
  for i in $(seq 1 20); do
    adb forward tcp:"$CDP_PORT" localabstract:chrome_devtools_remote 2>/dev/null || true
    if curl -sf "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null 2>&1; then
      break
    fi
    if (( i == 20 )); then err "Chrome CDP not reachable after 10s"; fi
    sleep 0.5
  done
fi
ok "Chrome CDP verified"

# Dismiss any lingering Chrome nag modals (notifications promo, first-run
# dialogs, etc.) before Playwright takes control of the browser.
# The flags file above prevents most modals on a clean emulator, but this
# handles edge cases where Chrome's state persists across sessions.
log "Checking for Chrome nag modals..."
sleep 1  # give Chrome a moment to render any dialogs
dismiss_chrome_modals

# Phase 4: Screen recording + tests
log "Phase 4: Running Playwright emulator tests"

adb shell "rm -f $RECORDING_PATH" 2>/dev/null || true
adb shell "screenrecord --time-limit 180 $RECORDING_PATH" &
RECORD_PID=$!

EXTRA_ARGS=()
[[ -n "$SPEC" ]] && EXTRA_ARGS+=("tests/emulator/$SPEC")

CDP_PORT=$CDP_PORT npx playwright test \
  --config=playwright.emulator.config.js \
  "${EXTRA_ARGS[@]}" || true
EXIT=${PIPESTATUS[0]:-$?}

kill "$RECORD_PID" 2>/dev/null || true
wait "$RECORD_PID" 2>/dev/null || true
sleep 1

# Phase 5: Collect artifacts
log "Phase 5: Collecting artifacts"
mkdir -p "$RESULTS_DIR"
if adb shell "test -f $RECORDING_PATH" 2>/dev/null; then
  adb pull "$RECORDING_PATH" "$RESULTS_DIR/recording.mp4" 2>/dev/null
  ok "Recording: $RESULTS_DIR/recording.mp4"
fi

# Phase 6: Extract video frames at test-critical moments
if [[ -f "$RESULTS_DIR/report.json" && -f "$RESULTS_DIR/recording.mp4" ]]; then
  log "Phase 6: Extracting video frames"
  bash scripts/extract-test-frames.sh --results "$RESULTS_DIR" || true
fi

# Phase 7: Generate narrative HTML report
if [[ -f "$RESULTS_DIR/report.json" ]]; then
  log "Phase 7: Generating workflow report"
  python3 scripts/generate-workflow-report.py --baseline "$RESULTS_DIR" || true
fi

log "Tests finished (exit $EXIT). Report: $RESULTS_DIR/workflow-report.html"
exit $EXIT
