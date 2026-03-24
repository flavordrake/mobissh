#!/usr/bin/env bash
# scripts/trace-check.sh — Check active TRACE freshness and suggest updates
#
# Usage:
#   scripts/trace-check.sh              # auto-detect active trace from CLAUDE.md
#   scripts/trace-check.sh <trace-dir>  # check a specific trace
#
# Reports:
#   - TRACE last modified time
#   - Commits since TRACE was last updated
#   - Recently modified files that may need TRACE documentation
#   - Missing TRACE sections (pivots, knowledge seed, etc.)

set -euo pipefail
cd "$(dirname "$0")/.."

# Find active TRACE
TRACE_DIR="${1:-}"
if [ -z "$TRACE_DIR" ]; then
  if [ -f "CLAUDE.md" ]; then
    TRACE_DIR=$(grep -oP '\.traces/trace-[^\s`/]+/' CLAUDE.md 2>/dev/null | head -1)
  fi
fi

if [ -z "$TRACE_DIR" ] || [ ! -d "$TRACE_DIR" ]; then
  echo "No active TRACE found."
  echo "  Init one: scripts/trace-init.sh <objective-slug>"
  echo "  Reference it in CLAUDE.md: > **Active TRACE**: \`.traces/trace-...\`"
  exit 0
fi

TRACE_MD="$TRACE_DIR/TRACE.md"
echo "Active TRACE: $TRACE_DIR"

# Last modified
if [ -f "$TRACE_MD" ]; then
  TRACE_MTIME=$(stat -c %Y "$TRACE_MD" 2>/dev/null || echo 0)
  TRACE_AGE=$(( $(date +%s) - TRACE_MTIME ))
  TRACE_AGE_MIN=$(( TRACE_AGE / 60 ))
  echo "TRACE.md last updated: ${TRACE_AGE_MIN}m ago"

  if [ $TRACE_AGE_MIN -gt 60 ]; then
    echo "  WARNING: TRACE is stale (>1 hour). Consider updating."
  fi
else
  echo "  WARNING: TRACE.md does not exist!"
fi

# Commits since TRACE was last updated
echo ""
echo "Commits since TRACE update:"
if [ -f "$TRACE_MD" ]; then
  NEWER_COMMITS=$(find . -name "*.ts" -o -name "*.js" -o -name "*.css" -o -name "*.html" -newer "$TRACE_MD" 2>/dev/null | grep -v node_modules | grep -v ".traces/" | head -20)
  COMMIT_COUNT=$(git log --oneline --since="$(stat -c %Y "$TRACE_MD" | xargs -I{} date -d @{} --iso-8601=seconds 2>/dev/null || echo '1 hour ago')" 2>/dev/null | wc -l)
  echo "  $COMMIT_COUNT commit(s) since last TRACE update"
  git log --oneline -5 2>/dev/null | sed 's/^/  /'
fi

# Recently modified source files
echo ""
echo "Recently modified files (last 30 min):"
find . -name "*.ts" -o -name "*.js" -o -name "*.css" -o -name "*.html" -o -name "*.sh" 2>/dev/null \
  | grep -v node_modules | grep -v ".traces/" | grep -v public/modules/ \
  | while read -r f; do
    MTIME=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    AGE=$(( $(date +%s) - MTIME ))
    if [ $AGE -lt 1800 ]; then
      echo "  $f ($(( AGE / 60 ))m ago)"
    fi
  done

# Check TRACE completeness
echo ""
echo "TRACE completeness:"
if [ -f "$TRACE_MD" ]; then
  check_section() {
    if grep -q "$1" "$TRACE_MD" 2>/dev/null; then
      if grep -A1 "$1" "$TRACE_MD" | grep -q "<!--"; then
        echo "  EMPTY: $1"
      else
        echo "  OK: $1"
      fi
    else
      echo "  MISSING: $1"
    fi
  }
  check_section "The \"Why\""
  check_section "The \"Ambiguity Gap\""
  check_section "The \"Knowledge Seed\""
  check_section "Performance Delta"
  check_section "Outcome Classification"
fi

# Check for pivots
echo ""
PIVOT_COUNT=$(ls "$TRACE_DIR/strategy/pivot_"*.md 2>/dev/null | wc -l)
echo "Pivots recorded: $PIVOT_COUNT"
if [ $PIVOT_COUNT -eq 0 ]; then
  echo "  (none — if strategy changed, record a pivot)"
fi

# Memory updates since TRACE
echo ""
echo "Memory updates (check if harvested into TRACE):"
find /home/dev/.claude/projects/ -name "*.md" -newer "$TRACE_MD" 2>/dev/null | head -5 | sed 's/^/  /'
