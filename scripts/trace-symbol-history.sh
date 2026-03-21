#!/usr/bin/env bash
# scripts/trace-symbol-history.sh — Track the evolution of a specific symbol
#
# Usage:
#   scripts/trace-symbol-history.sh <symbol> [--file <scope>]
#
# Uses git pickaxe (-S) to find when a symbol was added/removed,
# and -G for usage changes. Outputs linked issues from commit messages.

set -euo pipefail

MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"

cd "$(dirname "$0")/.."

usage() {
  echo "Usage: scripts/trace-symbol-history.sh <symbol> [--file <scope>]" >&2
  echo "" >&2
  echo "Track the evolution of a specific symbol (function, class, variable)." >&2
  echo "Uses git pickaxe to find when the symbol was added/removed." >&2
  exit 1
}

SYMBOL=""
FILE_SCOPE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --file) FILE_SCOPE="$2"; shift 2 ;;
    --help|-h) usage ;;
    -*) echo "Unknown option: $1" >&2; usage ;;
    *)
      if [ -z "$SYMBOL" ]; then
        SYMBOL="$1"
      else
        echo "Error: unexpected argument: $1" >&2
        usage
      fi
      shift
      ;;
  esac
done

if [ -z "$SYMBOL" ]; then
  usage
fi

# Extract #N issue/PR references from a string (empty string if none)
extract_refs() {
  echo "$1" | grep -oP '#\d+' || true
}

LOG_FORMAT="%h%x09%aI%x09%an%x09%s"

# Build file scope args
FILE_ARGS=()
if [ -n "$FILE_SCOPE" ]; then
  FILE_ARGS=("--" "$FILE_SCOPE")
fi

if ! PICKAXE_OUTPUT=$(git log --max-count=50 --format="$LOG_FORMAT" -S "$SYMBOL" "${FILE_ARGS[@]+"${FILE_ARGS[@]}"}" 2>&1); then
  echo "git log -S failed for: $SYMBOL" >&2
  exit 1
fi

if ! GREP_OUTPUT=$(git log --max-count=50 --format="$LOG_FORMAT" -G "$SYMBOL" "${FILE_ARGS[@]+"${FILE_ARGS[@]}"}" 2>&1); then
  echo "git log -G failed for: $SYMBOL" >&2
  exit 1
fi

# Merge and deduplicate by hash, preserving order
ALL_OUTPUT=$(printf '%s\n%s\n' "$PICKAXE_OUTPUT" "$GREP_OUTPUT" | awk -F'\t' '!seen[$1]++ && $1 != ""')

if [ -z "$ALL_OUTPUT" ]; then
  echo "No commits found for symbol: $SYMBOL"
  exit 0
fi

echo "Symbol: $SYMBOL"
if [ -n "$FILE_SCOPE" ]; then
  echo "Scope: $FILE_SCOPE"
fi
echo ""

# Build hash set of pickaxe hits for O(1) lookup (avoids O(N*M) grep per line)
declare -A PICKAXE_HASHES
if [ -n "$PICKAXE_OUTPUT" ]; then
  while IFS=$'\t' read -r ph _rest; do
    PICKAXE_HASHES["$ph"]=1
  done <<< "$PICKAXE_OUTPUT"
fi

while IFS=$'\t' read -r short_hash date author subject; do
  refs=$(extract_refs "$subject" | tr '\n' ' ' | sed 's/ $//')
  ref_str=""
  if [ -n "$refs" ]; then
    ref_str="  refs: $refs"
  fi

  # Determine if this was a pickaxe hit (added/removed) or grep hit (usage change)
  hit_type="changed"
  if [[ -v "PICKAXE_HASHES[$short_hash]" ]]; then
    hit_type="added/removed"
  fi

  printf "%s  %s  [%s]  %-20s  %s%s\n" "$short_hash" "$date" "$hit_type" "$author" "$subject" "$ref_str"
done <<< "$ALL_OUTPUT"
