#!/usr/bin/env bash
# scripts/emu-log.sh — capture the emulator's logcat for log↔screenshot
# correlation while debugging. Dumps the current buffer (default) or follows.
# Filters to the app + Flutter by default; pass a custom filter spec as args.
#
# Usage:
#   scripts/emu-log.sh                 # dump current buffer (app+flutter), to a file
#   scripts/emu-log.sh --clear         # clear the buffer first (fresh capture)
#   scripts/emu-log.sh -- <filterspec> # raw logcat filter spec (e.g. '*:E')
# Prints the log file path (last line).
set -euo pipefail

export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-/opt/android-sdk}"
ADB="$ANDROID_SDK_ROOT/platform-tools/adb"
OUTDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$OUTDIR"
STAMP="$(date +%Y%m%dT%H%M%S%z)"
OUT="$OUTDIR/logcat-${STAMP}.log"

DEV="$("$ADB" devices | awk 'NR>1 && $2=="device"{print $1; exit}')"
if [[ -z "$DEV" ]]; then
  echo "! emu-log: no live emulator (run scripts/emulator-ctl.sh ensure)" >&2
  exit 1
fi

if [[ "${1:-}" == "--clear" ]]; then
  "$ADB" -s "$DEV" logcat -c || true
  shift
fi

# Default filter: Flutter stdout/stderr + the app tag, everything else silenced.
FILTER=("flutter:V" "MobiSSH:V" "ActivityManager:I" "*:S")
if [[ "${1:-}" == "--" ]]; then
  shift
  FILTER=("$@")
fi

# -d = dump-and-exit (don't block). Use emu-log.sh in a loop for follow.
"$ADB" -s "$DEV" logcat -d -v time "${FILTER[@]}" > "$OUT"
echo "$OUT"
