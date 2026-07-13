#!/usr/bin/env bash
# scripts/record-when-ready.sh — wait for a marker line in a demo's output file,
# then screen-record the running emulator for a fixed duration and pull the mp4.
# Prints the absolute mp4 path as the only stdout success line.
#
# Usage: scripts/record-when-ready.sh <demo-output-file> <marker> <seconds>
set -euo pipefail

export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-/opt/android-sdk}"
ADB="$ANDROID_SDK_ROOT/platform-tools/adb"
OUTDIR="${MOBISSH_RECDIR:-/home/dev/workspace/mobissh/test-results/emulator-recordings}"
mkdir -p "$OUTDIR"

DEMO_OUT="$1"
MARKER="$2"
SECONDS_LEN="${3:-45}"
STAMP="$(date +%Y%m%dT%H%M%S%z)"
LOCAL="$OUTDIR/${STAMP}-bubble-demo.mp4"
REMOTE="/sdcard/bubble-demo.mp4"

DEV="$("$ADB" devices | awk 'NR>1 && $2=="device"{print $1; exit}')"
if [[ -z "$DEV" ]]; then
  echo "! no live emulator" >&2
  exit 1
fi

echo "> waiting for marker '$MARKER' in $DEMO_OUT (up to 240s)"
found=0
for _ in $(seq 1 120); do
  if [[ -f "$DEMO_OUT" ]] && grep -q "$MARKER" "$DEMO_OUT"; then
    found=1
    break
  fi
  sleep 2
done
if [[ "$found" -ne 1 ]]; then
  echo "! marker never appeared" >&2
  exit 2
fi

echo "> marker seen — recording ${SECONDS_LEN}s on $DEV"
"$ADB" -s "$DEV" shell screenrecord --time-limit "$SECONDS_LEN" --bit-rate 6000000 "$REMOTE"
echo "> pulling recording"
"$ADB" -s "$DEV" pull "$REMOTE" "$LOCAL"
"$ADB" -s "$DEV" shell rm -f "$REMOTE"
echo "$LOCAL"
