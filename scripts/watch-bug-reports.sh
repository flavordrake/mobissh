#!/usr/bin/env bash
# scripts/watch-bug-reports.sh
#
# Watch test-results/uploads/ for new bug-report JSON files. Emits one line
# per new bug to stdout — designed to be driven by Claude's Monitor tool.
#
# Each event line:
#   BUG <iso-timestamp> <abs-png-path> <title>
#
# Existing files at startup are recorded as "seen" so we only emit truly new
# reports. Polls every 2 seconds (local file system, no rate limit concern).

set -euo pipefail
cd "$(dirname "$0")/.."

UPLOADS_DIR="test-results/uploads"
MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
mkdir -p "$MOBISSH_TMPDIR"
SEEN_FILE="${MOBISSH_TMPDIR}/bug-report-watcher.seen"

mkdir -p "$UPLOADS_DIR"

# Seed the seen set with whatever's already there — only NEW reports trigger.
> "$SEEN_FILE"
for f in "$UPLOADS_DIR"/*-bug-report.json; do
  [ -e "$f" ] || continue
  basename "$f" >> "$SEEN_FILE"
done

# Poll loop. Each new *-bug-report.json file emits one event line.
while true; do
  for f in "$UPLOADS_DIR"/*-bug-report.json; do
    [ -e "$f" ] || continue
    name=$(basename "$f")
    if grep -Fxq "$name" "$SEEN_FILE"; then
      continue
    fi
    echo "$name" >> "$SEEN_FILE"

    # Pull the title from the JSON (fall back to the filename if jq misses).
    title=""
    if command -v node &>/dev/null; then
      title=$(node -e "
        try {
          const j = JSON.parse(require('fs').readFileSync('$f', 'utf8'));
          process.stdout.write(j.title || '');
        } catch(_) {}
      " 2>/dev/null || true)
    fi
    [ -z "$title" ] && title="(no title)"

    ts=${name%-bug-report.json}
    png_abs="$(pwd)/$UPLOADS_DIR/${ts}-bug-report.png"

    echo "BUG $ts $png_abs $title"
  done
  sleep 2
done
