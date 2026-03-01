#!/usr/bin/env bash
# scripts/gh-ops.sh — Common GitHub issue operations
#
# Wraps gh issue comment/edit/close so Claude Code can approve a single
# `bash scripts/gh-ops.sh` call instead of per-command approval for
# compound label/comment operations.
#
# Subcommands:
#   comment ISSUE --body-file FILE        Add comment from file
#   comment ISSUE --body "TEXT"           Add comment from string
#   labels  ISSUE [--add L ...] [--rm L ...]  Edit labels
#   close   ISSUE [--comment "TEXT"]      Close with optional comment
#   close   ISSUE [--body-file FILE]      Close with comment from file
#   search  QUERY                         Search open issues, JSON output
#   version                               Print code hash + server meta
#
# All progress goes to stderr, actionable output to stdout.

set -euo pipefail

usage() {
  echo "Usage: bash scripts/gh-ops.sh <command> [args]" >&2
  echo "Commands: comment, labels, close, search, version" >&2
  exit 1
}

[ $# -ge 1 ] || usage

CMD="$1"; shift

case "$CMD" in
  comment)
    [ $# -ge 1 ] || { echo "Error: comment requires ISSUE number" >&2; exit 1; }
    ISSUE="$1"; shift
    BODY=""
    BODY_FILE=""
    while [[ $# -gt 0 ]]; do
      case $1 in
        --body) BODY="$2"; shift 2 ;;
        --body-file) BODY_FILE="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
      esac
    done
    if [ -n "$BODY_FILE" ]; then
      BODY=$(cat "$BODY_FILE")
    elif [ -z "$BODY" ] && [ ! -t 0 ]; then
      BODY=$(cat)
    fi
    [ -n "$BODY" ] || { echo "Error: provide --body, --body-file, or pipe stdin" >&2; exit 1; }
    echo "Commenting on #${ISSUE}" >&2
    gh issue comment "$ISSUE" --body "$BODY"
    ;;

  labels)
    [ $# -ge 1 ] || { echo "Error: labels requires ISSUE number" >&2; exit 1; }
    ISSUE="$1"; shift
    ADD_LABELS=()
    RM_LABELS=()
    while [[ $# -gt 0 ]]; do
      case $1 in
        --add) ADD_LABELS+=("$2"); shift 2 ;;
        --rm|--remove) RM_LABELS+=("$2"); shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
      esac
    done
    ARGS=()
    for l in "${ADD_LABELS[@]+"${ADD_LABELS[@]}"}"; do
      ARGS+=(--add-label "$l")
    done
    for l in "${RM_LABELS[@]+"${RM_LABELS[@]}"}"; do
      ARGS+=(--remove-label "$l")
    done
    [ ${#ARGS[@]} -gt 0 ] || { echo "Error: provide --add or --rm labels" >&2; exit 1; }
    echo "Labels #${ISSUE}: +[${ADD_LABELS[*]+"${ADD_LABELS[*]}"}] -[${RM_LABELS[*]+"${RM_LABELS[*]}"}]" >&2
    gh issue edit "$ISSUE" "${ARGS[@]}" 2>/dev/null || true
    ;;

  close)
    [ $# -ge 1 ] || { echo "Error: close requires ISSUE number" >&2; exit 1; }
    ISSUE="$1"; shift
    BODY=""
    BODY_FILE=""
    while [[ $# -gt 0 ]]; do
      case $1 in
        --comment|--body) BODY="$2"; shift 2 ;;
        --body-file) BODY_FILE="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
      esac
    done
    if [ -n "$BODY_FILE" ]; then
      BODY=$(cat "$BODY_FILE")
    fi
    echo "Closing #${ISSUE}" >&2
    if [ -n "$BODY" ]; then
      gh issue close "$ISSUE" --comment "$BODY"
    else
      gh issue close "$ISSUE"
    fi
    ;;

  search)
    [ $# -ge 1 ] || { echo "Error: search requires QUERY" >&2; exit 1; }
    gh issue list --search "$1" --state open --json number,title --limit 5
    ;;

  version)
    CODE_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    PORT="${MOBISSH_PORT:-8081}"
    SERVER_META=$(curl -sf --max-time 3 "http://localhost:${PORT}/" 2>/dev/null \
      | grep -oP 'app-version"\s*content="\K[^"]+' || echo "server not running")
    echo "Code: ${CODE_HASH} | Server: ${SERVER_META}"
    ;;

  *)
    echo "Unknown command: $CMD" >&2
    usage
    ;;
esac
