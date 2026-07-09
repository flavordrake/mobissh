#!/usr/bin/env bash
# scripts/desktop-smoke.sh — Linux DESKTOP E2E smoke (#1012 Phase 0).
#
# Runs the desktop integration smoke on THIS box (no emulator, no adb):
#   1. toolchain check → scripts/setup-linux-desktop-toolchain.sh if missing
#   2. test-sshd up (Docker DNS test-sshd:22 — the host process reaches it
#      directly on the mobissh network; no socat/adb-reverse bridge)
#   3. Xvfb virtual display
#   4. `flutter test integration_test/desktop_smoke_test.dart -d linux`
#      (this builds the Linux debug bundle — the desktop build proof; run
#       `scripts/flutter-cmd.sh --in native build linux --release` for the
#       release-bundle proof)
#   5. screenshot of the live window via ffmpeg x11grab, captured every 2s
#      while the test runs; the LAST frame (the test holds the rendered
#      terminal for ~5s before exiting) lands in test-results/emulator-shots/
#      with the emu-shot.sh naming style. The path is the last stdout line.
#
# Usage: scripts/desktop-smoke.sh [integration_test/other_test.dart]
# Env: SMOKE_HOST (default test-sshd), SMOKE_PORT (default 22),
#      SMOKE_DISPLAY (default 97), MOBISSH_SHOTDIR (default
#      <repo>/test-results/emulator-shots).
#
# Exit 0 = smoke green (screenshot path printed). Exit 1 = test failed.
# Exit 2 = setup error.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"
LOGFILE="${MOBISSH_LOGDIR}/desktop-smoke.log"
exec > >(tee -a "$LOGFILE") 2>&1

TEST_FILE="${1:-integration_test/desktop_smoke_test.dart}"
NATIVE_DIR="${REPO_ROOT}/native"
SMOKE_HOST="${SMOKE_HOST:-test-sshd}"
SMOKE_PORT="${SMOKE_PORT:-22}"
DISPLAY_NUM=":${SMOKE_DISPLAY:-97}"
SCREEN_GEOM="1280x800"
SHOTDIR="${MOBISSH_SHOTDIR:-${REPO_ROOT}/test-results/emulator-shots}"
FRAMES_DIR="${MOBISSH_TMPDIR}/desktop-smoke-frames"
mkdir -p "$SHOTDIR"
rm -rf "$FRAMES_DIR"
mkdir -p "$FRAMES_DIR"

log() { echo "> $*"; }
err() { echo "! $*" >&2; }

XVFB_PID=""
WATCHER_PID=""
cleanup() {
  if [[ -n "$WATCHER_PID" ]] && kill -0 "$WATCHER_PID" 2>/dev/null; then
    kill "$WATCHER_PID" 2>/dev/null || true
  fi
  if [[ -n "$XVFB_PID" ]] && kill -0 "$XVFB_PID" 2>/dev/null; then
    kill "$XVFB_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# 1. Toolchain check — run the setup script only if something is missing.
missing=0
for t in clang cmake ninja pkg-config Xvfb ffmpeg; do
  command -v "$t" >/dev/null 2>&1 || missing=1
done
pkg-config --exists gtk+-3.0 2>/dev/null || missing=1
if [[ "$missing" == "1" ]]; then
  log "toolchain incomplete — running setup-linux-desktop-toolchain.sh"
  if ! "${REPO_ROOT}/scripts/setup-linux-desktop-toolchain.sh"; then
    err "toolchain setup failed"
    exit 2
  fi
else
  log "toolchain present"
fi

# 2. test-sshd reachable (bring it up + join the mobissh network if needed).
if ! getent hosts "$SMOKE_HOST" >/dev/null 2>&1; then
  log "$SMOKE_HOST not resolvable — running test-sshd-up.sh"
  if ! "${REPO_ROOT}/scripts/test-sshd-up.sh"; then
    err "test-sshd-up failed — cannot reach $SMOKE_HOST"
    exit 2
  fi
fi
log "$SMOKE_HOST resolves OK"

# 3. Virtual display. A stale Xvfb on this display (crashed prior run) leaves
# a lock file; remove it only if no live server owns it.
LOCKFILE="/tmp/.X${DISPLAY_NUM#:}-lock"
if [[ -e "$LOCKFILE" ]] && ! pgrep -f "Xvfb ${DISPLAY_NUM}" >/dev/null 2>&1; then
  rm -f "$LOCKFILE"
fi
if ! pgrep -f "Xvfb ${DISPLAY_NUM}" >/dev/null 2>&1; then
  log "starting Xvfb ${DISPLAY_NUM} (${SCREEN_GEOM}x24)"
  Xvfb "$DISPLAY_NUM" -screen 0 "${SCREEN_GEOM}x24" -nolisten tcp &
  XVFB_PID=$!
  sleep 1
else
  log "Xvfb ${DISPLAY_NUM} already running (reusing)"
fi

# 4. Frame watcher: grab the display every 2s while the test runs. The last
# frame captured is the held final terminal state (the test pumps ~5s after
# its assertions pass exactly so this watcher can catch it).
(
  n=0
  while true; do
    n=$((n + 1))
    ffmpeg -loglevel error -f x11grab -video_size "$SCREEN_GEOM" \
      -i "$DISPLAY_NUM" -frames:v 1 -y \
      "$(printf '%s/frame-%04d.png' "$FRAMES_DIR" "$n")" 2>/dev/null || true
    sleep 2
  done
) &
WATCHER_PID=$!

# 5. Run the integration test on the linux device. Builds the Linux debug
# bundle (incl. the libghostty prebuilt .so via the native-assets hook) —
# the same FFI path macOS uses with its dylib.
log "running $TEST_FILE on -d linux (host=$SMOKE_HOST:$SMOKE_PORT, display=$DISPLAY_NUM)"
STATUS=0
if ! DISPLAY="$DISPLAY_NUM" "${REPO_ROOT}/scripts/flutter-cmd.sh" --in "$NATIVE_DIR" \
    test "$TEST_FILE" -d linux \
    --dart-define="SMOKE_HOST=${SMOKE_HOST}" \
    --dart-define="SMOKE_PORT=${SMOKE_PORT}"; then
  STATUS=1
fi

# 6. Keep the last captured frame as the smoke screenshot (emu-shot naming).
kill "$WATCHER_PID" 2>/dev/null || true
WATCHER_PID=""
LAST_FRAME="$(ls -1 "$FRAMES_DIR"/frame-*.png 2>/dev/null | sort | tail -n 1 || true)"
if [[ -n "$LAST_FRAME" ]]; then
  STAMP="$(date +%Y%m%dT%H%M%S%z)"
  OUT="${SHOTDIR}/${STAMP}-desktop-smoke.png"
  cp "$LAST_FRAME" "$OUT"
  if [[ "$STATUS" == "0" ]]; then
    echo "+ SMOKE PASSED — $TEST_FILE"
  else
    echo "! SMOKE FAILED — $TEST_FILE (screenshot may show why)"
  fi
  echo "$OUT"
else
  err "no display frame captured (test may have failed before first paint)"
fi
exit "$STATUS"
