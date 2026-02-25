#!/usr/bin/env bash
# scripts/run-emulator-tests.sh
#
# Boot the Android emulator (if not already running), set up ADB port
# forwarding, launch Chrome, and run the Playwright emulator test suite.
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

log() { printf '\033[36m> %s\033[0m\n' "$*"; }
err() { printf '\033[31m! %s\033[0m\n' "$*" >&2; exit 1; }

# 1. Check emulator binary exists
command -v emulator &>/dev/null || err "emulator not found. Run: bash scripts/setup-avd.sh"
command -v adb &>/dev/null || err "adb not found. Run: bash scripts/setup-avd.sh"

# 2. Boot emulator if no device is connected
if ! adb devices 2>/dev/null | grep -q 'emulator\|device$'; then
  log "No device detected. Booting emulator ($AVD_NAME)..."
  emulator -avd "$AVD_NAME" -no-snapshot-save -gpu auto -no-audio &
  EMU_PID=$!

  log "Waiting for device to boot..."
  adb wait-for-device
  # Wait for boot_completed property
  for i in $(seq 1 120); do
    if adb shell getprop sys.boot_completed 2>/dev/null | grep -q '^1$'; then
      break
    fi
    if (( i == 120 )); then
      err "Emulator failed to boot within 120s"
    fi
    sleep 1
  done
  log "Emulator booted (PID $EMU_PID)."
else
  log "Emulator already running."
fi

# 3. Set up port forwarding
adb reverse tcp:$MOBISSH_PORT tcp:$MOBISSH_PORT 2>/dev/null || true
adb forward tcp:$CDP_PORT localabstract:chrome_devtools_remote 2>/dev/null || true
log "Port forwarding: emulator localhost:$MOBISSH_PORT -> host, CDP on :$CDP_PORT"

# 4. Enable Chrome remote debugging and launch
# Play Store Chrome is a release build — set-debug-app makes it expose the
# DevTools Unix socket that Playwright connects to over CDP.
log "Enabling Chrome remote debugging..."
adb shell am set-debug-app --persistent com.android.chrome 2>/dev/null || true
adb shell am force-stop com.android.chrome 2>/dev/null || true
sleep 1

log "Launching Chrome on emulator..."
adb shell am start -n com.android.chrome/com.google.android.apps.chrome.Main \
  -a android.intent.action.VIEW -d 'about:blank' 2>/dev/null || true
sleep 3

# Re-forward CDP after Chrome launch (socket appears after process starts)
adb forward tcp:$CDP_PORT localabstract:chrome_devtools_remote 2>/dev/null || true

# 5. Verify CDP is reachable
if ! curl -sf "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null 2>&1; then
  log "CDP not reachable. Trying to enable Chrome DevTools..."
  # Chrome needs to have been started at least once; retry forward
  sleep 3
  adb forward tcp:$CDP_PORT localabstract:chrome_devtools_remote 2>/dev/null || true
  if ! curl -sf "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null 2>&1; then
    err "Cannot reach Chrome DevTools on port $CDP_PORT. Ensure Chrome is running on the emulator."
  fi
fi
log "CDP connection verified."

# 6. Run Playwright tests
log "Running emulator tests..."
EXTRA_ARGS=()
if [[ -n "$SPEC" ]]; then
  EXTRA_ARGS+=("tests/emulator/$SPEC")
fi

CDP_PORT=$CDP_PORT npx playwright test \
  --config=playwright.emulator.config.js \
  "${EXTRA_ARGS[@]}"

EXIT=$?
log "Tests finished. Report: npx playwright show-report playwright-report-emulator"
exit $EXIT
