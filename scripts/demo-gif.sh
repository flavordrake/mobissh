#!/usr/bin/env bash
# scripts/demo-gif.sh — turn an `adb shell screenrecord` clip into a small,
# looping, palette-optimised GIF for README media (docs/media/), and dump a few
# PNG frames next to it so the result can be checked by eye before committing.
#
# Usage:
#   scripts/demo-gif.sh IN.mp4 OUT.gif [--start S] [--dur D] [--width W] [--fps F] [--speed X]
#
# Defaults: --start 0, --dur 8, --width 360, --fps 11, --speed 1 (2 = twice as fast).
# Two-pass palettegen/paletteuse (stats_mode=diff, bayer dither) keeps a phone UI
# clip of ~8s under ~2 MB. Prints the output size; warns above 2 MB.
# Check frames are written to $MOBISSH_TMPDIR/demo-gif/<OUT basename>-NN.png.
set -euo pipefail

MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR/demo-gif" "$MOBISSH_LOGDIR"

[[ $# -ge 2 ]] || { echo "Usage: scripts/demo-gif.sh IN.mp4 OUT.gif [--start S] [--dur D] [--width W] [--fps F] [--speed X]" >&2; exit 2; }
IN="$1"; OUT="$2"; shift 2
START=0; DUR=8; WIDTH=360; FPS=11; SPEED=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --start) START="$2"; shift 2 ;;
    --dur) DUR="$2"; shift 2 ;;
    --width) WIDTH="$2"; shift 2 ;;
    --fps) FPS="$2"; shift 2 ;;
    --speed) SPEED="$2"; shift 2 ;;
    *) echo "! unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ -f "$IN" ]] || { echo "! no such input: $IN" >&2; exit 2; }

LOG="$MOBISSH_LOGDIR/demo-gif.log"
PALETTE="$MOBISSH_TMPDIR/demo-gif/palette.png"
FILTERS="setpts=PTS/${SPEED},fps=${FPS},scale=${WIDTH}:-1:flags=lanczos"

ffmpeg -y -loglevel error -ss "$START" -t "$DUR" -i "$IN" \
  -vf "${FILTERS},palettegen=max_colors=128:stats_mode=diff" "$PALETTE" >>"$LOG" 2>&1
ffmpeg -y -loglevel error -ss "$START" -t "$DUR" -i "$IN" -i "$PALETTE" \
  -lavfi "${FILTERS}[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
  -loop 0 "$OUT" >>"$LOG" 2>&1

base="$(basename "$OUT" .gif)"
rm -f "$MOBISSH_TMPDIR/demo-gif/${base}"-*.png
ffmpeg -y -loglevel error -i "$OUT" -vf "select='not(mod(n\,$((FPS * 2))))'" -vsync vfr \
  "$MOBISSH_TMPDIR/demo-gif/${base}-%02d.png" >>"$LOG" 2>&1

bytes="$(stat -c %s "$OUT")"
echo "+ $OUT: $((bytes / 1024)) KiB, ${WIDTH}px wide, ${FPS} fps"
echo "  check frames: $MOBISSH_TMPDIR/demo-gif/${base}-*.png"
if (( bytes > 2 * 1024 * 1024 )); then
  echo "! over 2 MB: shorten --dur, lower --fps or --width" >&2
fi
