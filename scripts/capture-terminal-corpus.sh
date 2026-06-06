#!/usr/bin/env bash
# scripts/capture-terminal-corpus.sh — capture a REAL terminal screen from a live
# tmux pane into a replay fixture, so acceptance tests run against the owner's
# ACTUAL output (SGR colors, app-content-width wraps) instead of synthetic printf
# (the root cause of the +22..+28 URL misses). See the replay-acceptance design.
#
# Two modes:
#   (default) GRID SNAPSHOT — `tmux capture-pane -e -p` of a pane: the wrapped
#     screen the URL detector scans, WITH SGR, with tmux's literal newline at the
#     content-width wrap boundary. Faithful for the screen-scan detector. (tmux
#     strips OSC-8 from the grid — use --pipe for OSC-8 fixtures.)
#   --pipe PANE  RAW STREAM — `tmux pipe-pane` on a PLAIN (non-TUI) shell pane:
#     preserves OSC-8 verbatim. Never use on a full-screen TUI (cursor soup).
#
# Output: a .cast.json fixture {cols, rows, source, capturedAt, chunks:[{b64}]}.
#
# Usage:
#   scripts/capture-terminal-corpus.sh [--target T] [--scrollback N] [--out PATH]
#   scripts/capture-terminal-corpus.sh --pipe PANE --seconds S [--out PATH]
#     --target T      tmux pane (default: 'main' — the active pane of session main)
#     --scrollback N  extra scrollback lines to include (default 0 = visible only)
#     --out PATH      fixture path (default: native/test/fixtures/replay/<ts>.cast.json)

set -euo pipefail
cd "$(dirname "$0")/.."

MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
mkdir -p "$MOBISSH_TMPDIR"
FIXDIR="native/test/fixtures/replay"
mkdir -p "$FIXDIR"

TARGET="main"
SCROLLBACK=0
OUT=""
PIPE_PANE=""
PIPE_SECONDS=5
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --scrollback) SCROLLBACK="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --pipe) PIPE_PANE="$2"; shift 2 ;;
    --seconds) PIPE_SECONDS="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "! unknown option: $1" >&2; exit 2 ;;
  esac
done

TS="$(date +%Y%m%dT%H%M%S%z)"
RAW="${MOBISSH_TMPDIR}/capture-${TS}.raw"

emit_cast() {
  # $1 = raw bytes file, $2 = cols, $3 = rows, $4 = source label
  local b64
  b64="$(base64 -w0 < "$1")"
  printf '{\n  "cols": %s,\n  "rows": %s,\n  "source": "%s",\n  "capturedAt": "%s",\n  "chunks": [{ "b64": "%s" }]\n}\n' \
    "$2" "$3" "$4" "$TS" "$b64" > "$OUT"
}

if [[ -n "$PIPE_PANE" ]]; then
  [[ -z "$OUT" ]] && OUT="${FIXDIR}/pipe-${TS}.cast.json"
  read -r COLS ROWS < <(tmux display-message -p -t "$PIPE_PANE" '#{pane_width} #{pane_height}')
  echo "> pipe-pane capturing ${PIPE_SECONDS}s from $PIPE_PANE (${COLS}x${ROWS})..."
  tmux pipe-pane -o -t "$PIPE_PANE" "cat >> $RAW"
  sleep "$PIPE_SECONDS"
  tmux pipe-pane -t "$PIPE_PANE"  # toggle off
  emit_cast "$RAW" "$COLS" "$ROWS" "pipe-pane:$PIPE_PANE"
else
  [[ -z "$OUT" ]] && OUT="${FIXDIR}/capture-${TS}.cast.json"
  read -r COLS ROWS < <(tmux display-message -p -t "$TARGET" '#{pane_width} #{pane_height}')
  echo "> capture-pane grid snapshot from $TARGET (${COLS}x${ROWS}, -S -${SCROLLBACK})..."
  tmux capture-pane -e -p -t "$TARGET" -S "-${SCROLLBACK}" > "$RAW"
  emit_cast "$RAW" "$COLS" "$ROWS" "capture-pane:$TARGET"
fi

bytes="$(wc -c < "$RAW" | tr -d ' ')"
echo "+ wrote $OUT (${COLS}x${ROWS}, ${bytes} raw bytes)"
