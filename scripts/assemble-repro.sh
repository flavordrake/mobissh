#!/usr/bin/env bash
# scripts/assemble-repro.sh — assemble an in-app "record repro" frame burst
# (feedback_overlay.dart long-press → server saves <ts>-bug-report.frame-NNN.png)
# into a watchable mp4 + gif. The app captures at ~200ms intervals (5 fps).
#
# Usage:
#   scripts/assemble-repro.sh <ts-prefix>     e.g. 2026-06-05T17-30-00
#   scripts/assemble-repro.sh                 (newest frame set in uploads)
#
# Output lands next to the frames in test-results/uploads/ as
#   <ts>-repro.mp4  and  <ts>-repro.gif

set -euo pipefail
cd "$(dirname "$0")/.."

UPLOADS="test-results/uploads"
FPS=5  # matches feedback_overlay kReproInterval (200ms)

if [[ -n "${1:-}" ]]; then
  TS="$1"
else
  # Newest frame-001 in the uploads dir → its timestamp prefix.
  newest="$(ls -t "${UPLOADS}"/*-bug-report.frame-001.png 2>/dev/null | head -1 || true)"
  if [[ -z "$newest" ]]; then
    echo "! no *-bug-report.frame-001.png found in ${UPLOADS}" >&2
    exit 1
  fi
  base="$(basename "$newest")"
  TS="${base%-bug-report.frame-001.png}"
fi

PATTERN="${UPLOADS}/${TS}-bug-report.frame-%03d.png"
first="${UPLOADS}/${TS}-bug-report.frame-001.png"
if [[ ! -f "$first" ]]; then
  echo "! no frames for prefix '${TS}' (expected ${first})" >&2
  exit 1
fi

count="$(ls "${UPLOADS}/${TS}-bug-report.frame-"*.png 2>/dev/null | wc -l | tr -d ' ')"
MP4="${UPLOADS}/${TS}-repro.mp4"
GIF="${UPLOADS}/${TS}-repro.gif"

echo "> assembling ${count} frames @ ${FPS}fps → ${MP4}"
# -vf pad to even dimensions (yuv420p / libx264 requires even W/H).
ffmpeg -y -loglevel error -framerate "$FPS" -i "$PATTERN" \
  -vf "pad=ceil(iw/2)*2:ceil(ih/2)*2" -c:v libx264 -pix_fmt yuv420p "$MP4"
echo "> assembling gif → ${GIF}"
ffmpeg -y -loglevel error -framerate "$FPS" -i "$PATTERN" "$GIF"

echo "+ ${MP4}"
echo "+ ${GIF}"
