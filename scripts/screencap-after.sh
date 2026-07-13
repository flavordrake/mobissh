#!/usr/bin/env bash
# scripts/screencap-after.sh — wait N seconds, then screencap the emulator to a
# PNG. For visual/UX review of a transient on-device state (e.g. holding the
# terminal screen during an integration test). screencap emits PNG on stdout;
# this script owns the redirect to the output file (callers must not redirect).
#
# Usage: scripts/screencap-after.sh <delay_seconds> <output_png>

set -euo pipefail

DELAY="${1:?usage: screencap-after.sh <delay_seconds> <output_png>}"
OUT="${2:?usage: screencap-after.sh <delay_seconds> <output_png>}"

MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
mkdir -p "$MOBISSH_TMPDIR"

DEVICE="$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
if [ -z "$DEVICE" ]; then
  echo "! no online adb device" >&2
  exit 2
fi

sleep "$DELAY"
adb -s "$DEVICE" exec-out screencap -p > "$OUT"
echo "+ captured $OUT (device $DEVICE)"
