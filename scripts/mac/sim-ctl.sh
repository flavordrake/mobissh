#!/usr/bin/env bash
# scripts/mac/sim-ctl.sh — iOS Simulator lifecycle on the mac-runner (#1026).
#
# The simctl analog of scripts/emulator-ctl.sh: idempotent boot-or-REUSE of a
# named simulator, screenshot + log capture for agent debugging. Authored on
# fd-dev (Linux), EXECUTED ONLY on the runner Mac (macOS + full Xcode).
# Written for the macOS-stock bash 3.2 — no bash-4 features.
#
# Usage: scripts/mac/sim-ctl.sh {ensure|shot|log|list} [args]
#   ensure [sim-name]   boot iff not already booted; create the device first if
#                       it doesn't exist (latest iPhone devicetype + latest iOS
#                       runtime). Prints the UDID as the LAST stdout line so
#                       callers can capture it (mac-connect-test.sh does).
#   shot [label]        screenshot the booted simulator → timestamped PNG under
#                       test-results/simulator-shots/; prints the absolute path
#                       (only stdout line — emu-shot.sh contract).
#   log [minutes]       dump the last N minutes (default 5) of the booted sim's
#                       unified log filtered to the Flutter Runner process →
#                       $MOBISSH_LOGDIR; prints the file path (emu-log.sh contract).
#   list                available devices + runtimes (state overview).
#
# Env: SIM_NAME (default MobiSSH-iPhone)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"

SIM_NAME="${SIM_NAME:-MobiSSH-iPhone}"

log() { echo "> $*"; }
err() { echo "! $*" >&2; }

require_macos() {
  if [ "$(uname -s)" != "Darwin" ]; then
    err "sim-ctl.sh runs on macOS only (this is $(uname -s))"
    exit 2
  fi
  if ! xcrun simctl help >/dev/null 2>&1; then
    err "xcrun simctl unavailable — install full Xcode, then: sudo xcode-select -s /Applications/Xcode.app"
    exit 2
  fi
}

# UDID of the named device (any state), empty if absent.
device_udid() {
  xcrun simctl list devices | grep -F "$SIM_NAME (" | head -n1 \
    | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/'
}

# UDID of the named device iff Booted, empty otherwise.
booted_udid() {
  xcrun simctl list devices | grep -F "$SIM_NAME (" | grep -F '(Booted)' | head -n1 \
    | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/'
}

create_device() {
  # Latest iPhone devicetype + latest available iOS runtime.
  local devtype runtime
  # Newest iPhone by model NUMBER (devicetypes list is newest-FIRST in Xcode 26,
  # so tail picked iPhone-6s-Plus → incompatible with a current runtime, err 403).
  devtype="$(xcrun simctl list devicetypes | grep -E 'iPhone[- ][0-9]' \
    | sed -E 's/.*\((com\.apple\.CoreSimulator\.SimDeviceType\.iPhone-([0-9]+)[^)]*)\).*/\2 \1/' \
    | sort -rn | head -n1 | cut -d' ' -f2-)"
  runtime="$(xcrun simctl list runtimes | grep -E '^iOS .* - com\.apple' \
    | sed -E 's/.*(com\.apple\.CoreSimulator\.SimRuntime\.[A-Za-z0-9.-]+).*/\1/' | tail -n1)"
  if [ -z "$devtype" ] || [ -z "$runtime" ]; then
    err "no iPhone devicetype/iOS runtime found — download one: xcodebuild -downloadPlatform iOS"
    exit 2
  fi
  log "creating $SIM_NAME ($devtype, $runtime)"
  xcrun simctl create "$SIM_NAME" "$devtype" "$runtime" >/dev/null
}

cmd="${1:-ensure}"
case "$cmd" in
  ensure)
    if [ -n "${2:-}" ]; then SIM_NAME="$2"; fi
    require_macos
    udid="$(booted_udid || true)"
    if [ -n "$udid" ]; then
      log "reusing booted simulator $SIM_NAME ($udid)"
      echo "$udid"
      exit 0
    fi
    udid="$(device_udid || true)"
    if [ -z "$udid" ]; then
      create_device
      udid="$(device_udid)"
    fi
    log "booting $SIM_NAME ($udid)"
    xcrun simctl boot "$udid"
    # -b blocks until the boot handshake completes (the wait_booted analog).
    xcrun simctl bootstatus "$udid" -b
    log "BOOTED: $SIM_NAME"
    echo "$udid"
    ;;
  shot)
    require_macos
    LABEL="${2:-shot}"
    SAFE_LABEL="$(echo "$LABEL" | tr -c 'A-Za-z0-9._-' '_')"
    OUTDIR="${MOBISSH_SHOTDIR:-$REPO_ROOT/test-results/simulator-shots}"
    mkdir -p "$OUTDIR"
    OUT="$OUTDIR/$(date +%Y%m%dT%H%M%S%z)-${SAFE_LABEL}.png"
    xcrun simctl io booted screenshot "$OUT" >/dev/null
    echo "$OUT"
    ;;
  log)
    require_macos
    WINDOW_MIN="${2:-5}"
    OUT="$MOBISSH_LOGDIR/simlog-$(date +%Y%m%dT%H%M%S%z).log"
    # Runner is the Flutter app process; unified log is the logcat analog.
    xcrun simctl spawn booted log show --style syslog --last "${WINDOW_MIN}m" \
      --predicate 'process == "Runner"' > "$OUT"
    echo "$OUT"
    ;;
  list)
    require_macos
    xcrun simctl list devices available
    xcrun simctl list runtimes
    ;;
  *)
    err "usage: sim-ctl.sh {ensure|shot|log|list} [args]"
    exit 2
    ;;
esac
