#!/usr/bin/env bash
# scripts/mac/mac-connect-test.sh — run a MobiSSH integration test on the
# mac-runner against the shared Alpine test-sshd fixture (#1026).
#
# The macOS analog of scripts/native-connect-test.sh. The committed integration
# tests connect to 127.0.0.1:2222 / testuser / testpass on EVERY target; on the
# Mac that address is provided by a local socat hop over the tailnet:
#
#   Mac 127.0.0.1:2222 --(socat, this script)--> fd-dev:2222 (tailnet MagicDNS)
#                      --(fd-dev's scripts/testsshd-tailnet-bridge.sh)--> test-sshd:22
#
# PREREQUISITE on fd-dev: scripts/testsshd-tailnet-bridge.sh start
# (and `tailscale up` on this Mac — see scripts/mac/README.md).
#
# Authored on fd-dev (Linux), EXECUTED ONLY on the runner Mac. Written for the
# macOS-stock bash 3.2 — no bash-4 features.
#
# Usage: scripts/mac/mac-connect-test.sh [integration_test/foo.dart] [--target ios|macos]
#   test file      relative to native/ (default integration_test/connect_smoke_test.dart)
#   --target ios   boot-or-reuse the simulator via sim-ctl.sh, run on it (default)
#   --target macos run the desktop app natively on this Mac (-d macos; no
#                  simulator, no signing — the first-green target)
#
# Env: FDDEV_HOST (default fd-dev — the tailnet MagicDNS name),
#      MOBISSH_BRIDGE_PORT (default 2222)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"
LOGFILE="$MOBISSH_LOGDIR/mac-connect-test.log"
exec > >(tee -a "$LOGFILE") 2>&1

FDDEV_HOST="${FDDEV_HOST:-fd-dev}"
BRIDGE_PORT="${MOBISSH_BRIDGE_PORT:-2222}"
HOP_PID_FILE="$MOBISSH_TMPDIR/mac-connect-test-socat.pid"
NATIVE_DIR="$REPO_ROOT/native"

TEST_FILE="integration_test/connect_smoke_test.dart"
TARGET="ios"
while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    *) TEST_FILE="$1"; shift ;;
  esac
done
if [ "$TARGET" != "ios" ] && [ "$TARGET" != "macos" ]; then
  echo "! --target must be ios or macos" >&2
  exit 2
fi

log() { echo "> $*"; }
err() { echo "! $*" >&2; }

cleanup() {
  if [ -f "$HOP_PID_FILE" ]; then
    pid="$(cat "$HOP_PID_FILE")"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$HOP_PID_FILE"
  fi
}
trap cleanup EXIT

if [ "$(uname -s)" != "Darwin" ]; then
  err "mac-connect-test.sh runs on macOS only (this is $(uname -s))"
  exit 2
fi
if ! command -v socat >/dev/null 2>&1; then
  err "socat not installed (brew install socat)"
  exit 2
fi
if ! command -v flutter >/dev/null 2>&1; then
  err "flutter not on PATH"
  exit 2
fi

# 1. Local hop: 127.0.0.1:2222 → fd-dev:2222 over the tailnet (the adb-reverse
#    analog — one socat, one line). Reuse a hop that's already listening.
if nc -z 127.0.0.1 "$BRIDGE_PORT" 2>/dev/null; then
  log "127.0.0.1:${BRIDGE_PORT} already listening — reusing existing hop"
else
  log "starting socat 127.0.0.1:${BRIDGE_PORT} -> ${FDDEV_HOST}:${BRIDGE_PORT}"
  socat "TCP-LISTEN:${BRIDGE_PORT},bind=127.0.0.1,fork,reuseaddr" \
    "TCP:${FDDEV_HOST}:${BRIDGE_PORT}" &
  echo $! > "$HOP_PID_FILE"
  sleep 1
fi

# 2. Verify the fixture actually answers end-to-end before spending a build.
if ! nc -z 127.0.0.1 "$BRIDGE_PORT" 2>/dev/null; then
  err "127.0.0.1:${BRIDGE_PORT} not listening — socat hop failed"
  exit 2
fi
if ! nc -z "$FDDEV_HOST" "$BRIDGE_PORT" 2>/dev/null; then
  err "${FDDEV_HOST}:${BRIDGE_PORT} unreachable over the tailnet"
  err "on fd-dev run: scripts/testsshd-tailnet-bridge.sh start ; here run: tailscale status"
  exit 2
fi
log "fixture reachable: 127.0.0.1:${BRIDGE_PORT} -> ${FDDEV_HOST}:${BRIDGE_PORT} -> test-sshd:22"

# 3. Resolve the flutter device id.
if [ "$TARGET" = "ios" ]; then
  UDID="$("$REPO_ROOT/scripts/mac/sim-ctl.sh" ensure | tail -n1)"
  DEVICE="$UDID"
  log "target: iOS Simulator ($UDID)"
else
  DEVICE="macos"
  log "target: macOS desktop (native run on this Mac)"
fi

# 4. Run the integration test (same committed file as Android/emulator).
#    The committed tests default their SSH target to the docker DNS name
#    `test-sshd:22` — great on fd-dev, unresolvable on the Mac — and read
#    SMOKE_HOST/SMOKE_PORT dart-defines. Point them at the local hop
#    (127.0.0.1:2222) so they reach the fixture via the tailnet bridge
#    (mac-runner verified, 2026-07-11: without this the run fails
#    `Failed host lookup: 'test-sshd'`).
SMOKE_HOST="${SMOKE_HOST:-127.0.0.1}"
SMOKE_PORT="${SMOKE_PORT:-$BRIDGE_PORT}"
log "flutter test $TEST_FILE -d $DEVICE (SMOKE_HOST=$SMOKE_HOST SMOKE_PORT=$SMOKE_PORT) ($(date +%Y%m%dT%H%M%S%z))"
cd "$NATIVE_DIR"
rc=0
flutter test "$TEST_FILE" -d "$DEVICE" \
  --dart-define=SMOKE_HOST="$SMOKE_HOST" --dart-define=SMOKE_PORT="$SMOKE_PORT" || rc=$?
if [ $rc -eq 0 ]; then
  log "PASS: $TEST_FILE on $TARGET"
else
  err "FAIL: $TEST_FILE on $TARGET (exit $rc) — see $LOGFILE"
fi
exit $rc
