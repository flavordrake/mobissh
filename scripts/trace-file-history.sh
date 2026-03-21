#!/usr/bin/env bash
# scripts/trace-file-history.sh — Query the full trajectory of a file through source control
#
# Usage:
#   scripts/trace-file-history.sh <file-path> [--json]
#
# Outputs a structured timeline of commits touching the file,
# cross-referenced with issues/PRs via commit message parsing (#N patterns).

set -euo pipefail

MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"

cd "$(dirname "$0")/.."

usage() {
  echo "Usage: scripts/trace-file-history.sh <file-path> [--json]" >&2
  echo "" >&2
  echo "Query the full trajectory of a file through source control." >&2
  echo "Cross-references issues/PRs via commit message parsing (#N patterns)." >&2
  exit 1
}

FILE=""
JSON_MODE=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --json) JSON_MODE=true; shift ;;
    --help|-h) usage ;;
    -*) echo "Unknown option: $1" >&2; usage ;;
    *)
      if [ -z "$FILE" ]; then
        FILE="$1"
      else
        echo "Error: unexpected argument: $1" >&2
        usage
      fi
      shift
      ;;
  esac
done

if [ -z "$FILE" ]; then
  usage
fi

# Extract #N issue/PR references from a string (empty string if none)
extract_refs() {
  echo "$1" | grep -oP '#\d+' || true
}

LOG_FORMAT="%H%x09%h%x09%aI%x09%an%x09%s"
if ! LOG_OUTPUT=$(git log --follow --max-count=50 --format="$LOG_FORMAT" -- "$FILE" 2>&1); then
  echo "git log failed for: $FILE" >&2
  exit 1
fi

if [ -z "$LOG_OUTPUT" ]; then
  echo "No commits found for: $FILE" >&2
  exit 0
fi

if [ "$JSON_MODE" = true ]; then
  echo "["
  FIRST=true
  while IFS=$'\t' read -r full_hash short_hash date author subject; do
    # Extract issue/PR references (#N)
    refs=$(extract_refs "$subject" | tr '\n' ',' | sed 's/,$//')
    if [ "$FIRST" = true ]; then
      FIRST=false
    else
      echo ","
    fi
    # Escape strings for JSON
    subject_escaped=$(echo "$subject" | sed 's/\\/\\\\/g; s/"/\\"/g')
    author_escaped=$(echo "$author" | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '  {"hash":"%s","short_hash":"%s","date":"%s","author":"%s","subject":"%s","refs":[%s]}' \
      "$full_hash" "$short_hash" "$date" "$author_escaped" "$subject_escaped" \
      "$(echo "$refs" | sed 's/#\([0-9]*\)/"\1"/g')"
  done <<< "$LOG_OUTPUT"
  echo ""
  echo "]"
else
  # Plain text timeline
  while IFS=$'\t' read -r full_hash short_hash date author subject; do
    refs=$(extract_refs "$subject" | tr '\n' ' ' | sed 's/ $//')
    ref_str=""
    if [ -n "$refs" ]; then
      ref_str="  refs: $refs"
    fi
    printf "%s  %s  %-20s  %s%s\n" "$short_hash" "$date" "$author" "$subject" "$ref_str"
  done <<< "$LOG_OUTPUT"
fi
