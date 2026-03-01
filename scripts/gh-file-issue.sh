#!/usr/bin/env bash
# scripts/gh-file-issue.sh — File a GitHub issue with body from file/stdin
#
# Wraps gh issue create with proper output handling so Claude Code can
# approve a single `bash scripts/gh-file-issue.sh` call instead of
# approving compound heredoc + redirection patterns individually.
#
# Usage:
#   bash scripts/gh-file-issue.sh --title "bug: title" --label bug [--label ux] --body-file /tmp/body.md
#   echo "body text" | bash scripts/gh-file-issue.sh --title "feat: title" --label feature
#
# Options:
#   --title TEXT        Issue title (required)
#   --label LABEL       Label to apply (repeatable)
#   --body-file FILE    Read body from file (default: stdin)
#   --dry-run           Print the gh command without executing
#
# Output: issue URL on stdout, progress on stderr
# Exit: 0 on success, 1 on error

set -euo pipefail

TITLE=""
LABELS=()
BODY_FILE=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --title) TITLE="$2"; shift 2 ;;
    --label) LABELS+=("$2"); shift 2 ;;
    --body-file) BODY_FILE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$TITLE" ]; then
  echo "Error: --title is required" >&2
  exit 1
fi

# Read body from file or stdin
if [ -n "$BODY_FILE" ]; then
  if [ ! -f "$BODY_FILE" ]; then
    echo "Error: body file not found: $BODY_FILE" >&2
    exit 1
  fi
  BODY=$(cat "$BODY_FILE")
elif [ ! -t 0 ]; then
  BODY=$(cat)
else
  echo "Error: provide --body-file or pipe body via stdin" >&2
  exit 1
fi

# Build label args
LABEL_ARGS=()
for label in "${LABELS[@]}"; do
  LABEL_ARGS+=(--label "$label")
done

if [ "$DRY_RUN" = true ]; then
  echo "gh issue create --title \"$TITLE\" ${LABEL_ARGS[*]:-} --body <${#BODY} chars>" >&2
  exit 0
fi

echo "Filing: $TITLE" >&2

# Create the issue — gh outputs the URL to stdout
gh issue create --title "$TITLE" "${LABEL_ARGS[@]}" --body "$BODY"
