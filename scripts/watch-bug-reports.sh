#!/usr/bin/env bash
# scripts/watch-bug-reports.sh
#
# Watch test-results/uploads/ for new bug-report JSON files. Emits one line
# per new file to stdout — designed to be driven by Claude's Monitor tool.
#
# Event lines:
#   BUG  <iso-timestamp> <abs-png-path>  <title>             (user-filed)
#
# The DROP lines for /api/drop-telemetry went with that route (#1261).
#
# Existing files at startup are recorded as "seen" so we only emit truly new
# events. Polls every 2 seconds (local file system, no rate limit concern).

set -euo pipefail
cd "$(dirname "$0")/.."

UPLOADS_DIR="test-results/uploads"
MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
mkdir -p "$MOBISSH_TMPDIR"
SEEN_FILE="${MOBISSH_TMPDIR}/bug-report-watcher.seen"

mkdir -p "$UPLOADS_DIR"

# Seed the seen set with whatever's already there — only NEW files trigger.
: > "$SEEN_FILE"
for f in "$UPLOADS_DIR"/*-bug-report.json; do
  [ -e "$f" ] || continue
  basename "$f" >> "$SEEN_FILE"
done

read_field() {
  local file="$1" field="$2"
  if command -v node &>/dev/null; then
    node -e "
      try {
        const j = JSON.parse(require('fs').readFileSync('$file', 'utf8'));
        process.stdout.write(String(j['$field'] ?? ''));
      } catch(_) {}
    " 2>/dev/null || true
  fi
}

while true; do
  # Bug reports — user-filed, may have screenshot.
  for f in "$UPLOADS_DIR"/*-bug-report.json; do
    [ -e "$f" ] || continue
    name=$(basename "$f")
    if grep -Fxq "$name" "$SEEN_FILE"; then continue; fi
    echo "$name" >> "$SEEN_FILE"

    title=$(read_field "$f" title)
    [ -z "$title" ] && title="(no title)"
    ts=${name%-bug-report.json}
    png_abs="$(pwd)/$UPLOADS_DIR/${ts}-bug-report.png"
    echo "BUG $ts $png_abs $title"
  done

  sleep 2
done
