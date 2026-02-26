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

log() { printf '\033[36m> %s\033[0m\n' "$*"; }
ok()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
err() { printf '\033[31m! %s\033[0m\n' "$*" >&2; exit 1; }

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

# Phase 3: ADB forwarding + Chrome CDP
log "Phase 3: ADB forwarding and Chrome CDP"

adb reverse tcp:"$MOBISSH_PORT" tcp:"$MOBISSH_PORT" 2>/dev/null || true
adb forward tcp:"$CDP_PORT" localabstract:chrome_devtools_remote 2>/dev/null || true
ok "Port forwarding configured (server :$MOBISSH_PORT, CDP :$CDP_PORT)"

# Enable Chrome remote debugging (Play Store Chrome needs set-debug-app to
# expose the DevTools Unix socket)
adb shell am set-debug-app --persistent com.android.chrome 2>/dev/null || true

# Check if Chrome is responding to CDP already
if ! curl -sf "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null 2>&1; then
  log "Chrome not responding to CDP, restarting..."
  adb shell am force-stop com.android.chrome 2>/dev/null || true
  sleep 1
  adb shell am start -n com.android.chrome/com.google.android.apps.chrome.Main \
    -a android.intent.action.VIEW -d 'about:blank' 2>/dev/null || true

  # Wait for CDP socket to come alive (Chrome needs a moment after launch)
  for i in $(seq 1 20); do
    adb forward tcp:$CDP_PORT localabstract:chrome_devtools_remote 2>/dev/null || true
    if curl -sf "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null 2>&1; then
      break
    fi
    if (( i == 20 )); then err "Chrome CDP not reachable after 10s"; fi
    sleep 0.5
  done
fi
ok "Chrome CDP verified"

# Phase 4: Run tests
log "Phase 4: Running Playwright emulator tests"

EXTRA_ARGS=()
if [[ -n "$SPEC" ]]; then
  EXTRA_ARGS+=("tests/emulator/$SPEC")
fi

CDP_PORT=$CDP_PORT npx playwright test \
  --config=playwright.emulator.config.js \
  "${EXTRA_ARGS[@]}"

EXIT=$?
log "Tests finished (exit $EXIT). Report: npx playwright show-report playwright-report-emulator"
exit $EXIT
