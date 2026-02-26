#!/usr/bin/env bash
# scripts/review-recording.sh
#
# Extracts evenly-spaced frames from an emulator screen recording for quick
# visual review. Outputs to a review/ subdirectory next to the recording.
#
# Usage:
#   bash scripts/review-recording.sh                          # defaults
#   bash scripts/review-recording.sh --interval 3             # every 3 seconds
#   bash scripts/review-recording.sh --recording path/to/mp4  # custom recording
#   bash scripts/review-recording.sh --open                   # open output dir

set -euo pipefail

RECORDING="test-results/emulator/recording.mp4"
INTERVAL=5
OPEN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --recording)  RECORDING="$2"; shift 2 ;;
    --interval)   INTERVAL="$2"; shift 2 ;;
    --open)       OPEN=true; shift ;;
    *)            echo "Usage: $0 [--recording path] [--interval secs] [--open]" >&2; exit 1 ;;
  esac
done

command -v ffmpeg &>/dev/null || { echo "ffmpeg not found" >&2; exit 1; }
[[ -f "$RECORDING" ]] || { echo "Recording not found: $RECORDING" >&2; exit 1; }

OUTDIR="$(dirname "$RECORDING")/review"
rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"

DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$RECORDING" | cut -d. -f1)
echo "Recording: $RECORDING (${DURATION}s), sampling every ${INTERVAL}s"

COUNT=0
for t in $(seq 0 "$INTERVAL" "$DURATION"); do
  PADDED=$(printf '%03d' "$t")
  ffmpeg -y -ss "$t" -i "$RECORDING" -frames:v 1 -q:v 2 "$OUTDIR/frame-${PADDED}s.png" 2>/dev/null
  COUNT=$((COUNT + 1))
done

echo "Extracted $COUNT frames to $OUTDIR/"

if [[ "$OPEN" == "true" ]] && command -v xdg-open &>/dev/null; then
  xdg-open "$OUTDIR"
fi
