#!/usr/bin/env bash
# scripts/emulator-cleanup.sh — clear stale AVD/emulator state so the AVD boots.
#
# A crashed emulator leaves: (1) stale lock files (*.lock under the .avd) and
# (2) a stale "running" instance registry (~/.android/avd/running/<pid>) that
# point at a DEAD pid, which makes a fresh boot believe an instance is already
# running. It also leaves <defunct> adb/crashpad/qemu zombies parented to PID 1
# — those are already dead and only a container restart fully clears them
# (reported here, not killable). Restarts the adb fork-server too.
#
# Usage: scripts/emulator-cleanup.sh [--force]
#   --force   kill any LIVE emulator/qemu first (default: refuse if one is live,
#             so we never yank the locks out from under a running emulator).

set -euo pipefail

MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"
LOGFILE="${MOBISSH_LOGDIR}/emulator-cleanup.log"
exec > >(tee -a "$LOGFILE") 2>&1

AVD_HOME="${ANDROID_AVD_HOME:-$HOME/.android/avd}"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

echo "> emulator-cleanup: AVD_HOME=$AVD_HOME force=$FORCE"

# 1. LIVE emulator/qemu? (exclude zombies: STAT containing Z, and the defunct
#    cmdline is empty so they won't match a real run anyway.)
LIVE=$(ps -eo pid,stat,comm | awk '($3 ~ /qemu-system|emulator/) && ($2 !~ /Z/) {print $1}' || true)
if [ -n "$LIVE" ]; then
  if [ "$FORCE" -eq 1 ]; then
    echo "> --force: killing live emulator/qemu: $LIVE"
    for p in $LIVE; do kill "$p" 2>/dev/null || true; done
    sleep 2
    for p in $LIVE; do kill -9 "$p" 2>/dev/null || true; done
  else
    echo "! live emulator/qemu running (PIDs: $LIVE) — refusing to touch locks." >&2
    echo "  Re-run with --force to kill it first." >&2
    exit 1
  fi
else
  echo "> no LIVE emulator/qemu (only defunct, if any) — safe to clear stale state"
fi

# 2. Stale lock files.
echo "> removing stale AVD lock files:"
find "$AVD_HOME" -name '*.lock' -print -delete 2>/dev/null || true

# 3. Stale running-instance registry (no live emulator → all entries are stale).
if [ -d "$AVD_HOME/running" ]; then
  echo "> clearing stale running-instance registry: $AVD_HOME/running"
  rm -rf "${AVD_HOME:?}/running"
fi

# 4. Restart adb (clears the fork-server; lets init reap its defunct children).
echo "> restarting adb server"
adb kill-server 2>/dev/null || true
adb start-server 2>/dev/null || true

# 5. Report zombies (not killable here — PPID 1; container restart clears them).
ZCOUNT=$(ps -eo stat,comm | awk '$1 ~ /Z/ {c++} END {print c+0}')
echo "> defunct/zombie processes remaining: ${ZCOUNT} (parented to init — a"
echo "  container restart fully clears them; not boot-blocking)"

# 6. Final state.
echo "> adb devices:"
adb devices -l 2>&1 || true
echo "+ emulator-cleanup done — AVD can boot fresh (scripts/setup-avd.sh or a"
echo "  direct: scripts/flutter-cmd.sh has the SDK; emulator @MobiSSH_Pixel7)"
