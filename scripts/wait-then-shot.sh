#!/usr/bin/env bash
# scripts/wait-then-shot.sh — wait for a marker line in a background test's
# output file, then grab N emulator screenshots. Prints each PNG path.
#
# Usage: scripts/wait-then-shot.sh <output-file> <marker> [count] [gap-seconds]
set -euo pipefail

OUT_FILE="$1"
MARKER="$2"
COUNT="${3:-2}"
GAP="${4:-3}"

found=0
for _ in $(seq 1 130); do
  if [[ -f "$OUT_FILE" ]] && grep -q "$MARKER" "$OUT_FILE"; then
    found=1
    break
  fi
  sleep 2
done
if [[ "$found" -ne 1 ]]; then
  echo "! marker '$MARKER' never appeared" >&2
  exit 2
fi

for i in $(seq 1 "$COUNT"); do
  /home/dev/workspace/mobissh/scripts/emu-shot.sh "osc8repro-$i"
  sleep "$GAP"
done
