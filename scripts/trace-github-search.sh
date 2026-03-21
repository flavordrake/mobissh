#!/usr/bin/env bash
# scripts/trace-github-search.sh — Wrapper around GitHub search for deeper context
#
# Usage:
#   scripts/trace-github-search.sh <query> [--type code|issues|prs]
#
# Uses scripts/gh-ops.sh search (never raw gh) to find issues mentioning
# a file or symbol, and PRs that touched a file.

set -euo pipefail

MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"

cd "$(dirname "$0")/.."

usage() {
  echo "Usage: scripts/trace-github-search.sh <query> [--type code|issues|prs]" >&2
  echo "" >&2
  echo "Search GitHub for issues, PRs, or code mentioning a file or symbol." >&2
  echo "Wraps scripts/gh-ops.sh search (never raw gh commands)." >&2
  exit 1
}

QUERY=""
SEARCH_TYPE="issues"

while [[ $# -gt 0 ]]; do
  case $1 in
    --type)
      SEARCH_TYPE="$2"
      case "$SEARCH_TYPE" in
        code|issues|prs) ;;
        *) echo "Error: --type must be code, issues, or prs" >&2; usage ;;
      esac
      shift 2
      ;;
    --help|-h) usage ;;
    -*) echo "Unknown option: $1" >&2; usage ;;
    *)
      if [ -z "$QUERY" ]; then
        QUERY="$1"
      else
        echo "Error: unexpected argument: $1" >&2
        usage
      fi
      shift
      ;;
  esac
done

if [ -z "$QUERY" ]; then
  usage
fi

echo "Searching GitHub ($SEARCH_TYPE): $QUERY"
echo ""

case "$SEARCH_TYPE" in
  issues)
    # Use gh-ops.sh search for issues
    RESULT=$(scripts/gh-ops.sh search "$QUERY" 2>/dev/null)
    if [ -z "$RESULT" ] || [ "$RESULT" = "[]" ]; then
      echo "No open issues found matching: $QUERY"
    else
      echo "Open issues matching '$QUERY':"
      echo "$RESULT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data:
    print(f\"  #{item['number']}  {item['title']}\")
" 2>/dev/null || echo "$RESULT"
    fi
    ;;

  prs)
    # Search PRs by looking at git log for commits mentioning the query
    echo "PRs referencing '$QUERY' (from git log):"
    PR_REFS=$(git log --all --oneline --grep="$QUERY" 2>/dev/null | head -20)
    if [ -z "$PR_REFS" ]; then
      echo "  No commits found mentioning: $QUERY"
    else
      echo "$PR_REFS" | while IFS= read -r line; do
        refs=$(echo "$line" | grep -oP '#\d+' | tr '\n' ' ' | sed 's/ $//')
        if [ -n "$refs" ]; then
          echo "  $line  (refs: $refs)"
        else
          echo "  $line"
        fi
      done
    fi
    ;;

  code)
    # Search for the query in the current codebase using git grep
    echo "Code references for '$QUERY':"
    CODE_REFS=$(git grep -l "$QUERY" 2>/dev/null | head -20)
    if [ -z "$CODE_REFS" ]; then
      echo "  No code references found for: $QUERY"
    else
      echo "$CODE_REFS" | while IFS= read -r file; do
        count=$(git grep -c "$QUERY" "$file" 2>/dev/null | cut -d: -f2)
        echo "  $file  ($count matches)"
      done
    fi
    ;;
esac
