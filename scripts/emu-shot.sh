#!/usr/bin/env bash
# scripts/emu-shot.sh — grab a screenshot off the running emulator so the agent
# can Read it (visual debugging of the always-on emulator). Writes a timestamped
# PNG and prints its absolute path (the only stdout line is the path, so callers
# can capture it).
#
# Usage: scripts/emu-shot.sh [label]
set -euo pipefail

export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-/opt/android-sdk}"
ADB="$ANDROID_SDK_ROOT/platform-tools/adb"
OUTDIR="${MOBISSH_SHOTDIR:-/home/dev/workspace/mobissh/test-results/emulator-shots}"
mkdir -p "$OUTDIR"

LABEL="${1:-shot}"
SAFE_LABEL="$(echo "$LABEL" | tr -c 'A-Za-z0-9._-' '_')"
STAMP="$(date +%Y%m%dT%H%M%S%z)"
OUT="$OUTDIR/${STAMP}-${SAFE_LABEL}.png"

DEV="$("$ADB" devices | awk 'NR>1 && $2=="device"{print $1; exit}')"
if [[ -z "$DEV" ]]; then
  echo "! emu-shot: no live emulator (run scripts/emulator-ctl.sh ensure)" >&2
  exit 1
fi

# exec-out streams the PNG bytes directly (no on-device temp file / pull dance).
"$ADB" -s "$DEV" exec-out screencap -p > "$OUT"
echo "$OUT"
