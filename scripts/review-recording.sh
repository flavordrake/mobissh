#!/usr/bin/env bash
# scripts/review-recording.sh
#
# Extracts evenly-spaced frames from a screen recording for quick visual review.
# Outputs to a review/ subdirectory next to the recording.
#
# Usage:
#   scripts/review-recording.sh                                  # defaults (Appium recording)
#   scripts/review-recording.sh --interval 3                     # every 3 seconds
#   scripts/review-recording.sh --recording path/to/file.webm    # custom recording
#   scripts/review-recording.sh --open                           # open output dir
#
# Default recording path: test-results-appium/recording.webm (run-appium-tests.sh output)
# For emulator tests use: --recording test-results/emulator/recording.mp4
#
# NOTE — debug overlay artifacts in recordings:
#   run-appium-tests.sh enables show_touches and pointer_location for the
#   entire test run. These are cosmetic overlays and appear in all recordings:
#   - Green circles at touch points (show_touches): disappear on finger lift;
#     the last circle may linger ~100ms between test cases — expected behavior.
#   - Coordinate bar at screen top (pointer_location): always visible when
#     enabled, holds last-touch coordinates between gestures — also expected.
#   Both overlays are disabled after the run. They do not affect assertions.

set -euo pipefail

RECORDING="test-results-appium/recording.webm"
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
