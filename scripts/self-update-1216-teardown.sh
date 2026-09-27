#!/usr/bin/env bash
# scripts/self-update-1216-teardown.sh — pairs with self-update-1216-setup.sh.
# Stops the appop granter, records which activity is resumed (the hand-off's
# evidence: the package installer should be on top) plus a screenshot, then
# backs out of the installer so later tests start from a clean screen.
set -uo pipefail

MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"
PIDFILE="${MOBISSH_TMPDIR}/self-update-1216-granter.pid"
EVIDENCE="${MOBISSH_LOGDIR}/self-update-1216-teardown.log"

if [[ -f "$PIDFILE" ]]; then
  kill "$(cat "$PIDFILE")" 2>/dev/null || true
  rm -f "$PIDFILE"
fi

if [[ -n "${EMU_ADBD_ENDPOINT:-}" ]]; then
  DEVICE="$EMU_ADBD_ENDPOINT"
else
  DEVICE="$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
fi
[[ -n "$DEVICE" ]] || { echo "! teardown: no adb device"; exit 0; }

{
  echo "> $(date -u +%Y-%m-%dT%H:%M:%SZ) resumed activity after the self-update test:"
  adb -s "$DEVICE" shell dumpsys activity activities | grep -E 'mResumedActivity|topResumedActivity|ResumedActivity' || true
} | tee "$EVIDENCE"
adb -s "$DEVICE" exec-out screencap -p >"${MOBISSH_LOGDIR}/self-update-1216-teardown.png" || true
echo "> evidence: ${EVIDENCE} + ${MOBISSH_LOGDIR}/self-update-1216-teardown.png"

adb -s "$DEVICE" shell input keyevent KEYCODE_BACK || true
adb -s "$DEVICE" shell input keyevent KEYCODE_HOME || true
exit 0
