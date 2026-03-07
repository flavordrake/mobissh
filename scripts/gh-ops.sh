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
#   pr-create --head BRANCH --title T --body-file F [--label L ...]  Create PR
#   pr-merge  PR_NUM [--squash|--merge|--rebase]  Merge and delete branch
#   pr-close  PR_NUM [--comment "TEXT"]   Close PR with optional comment
#   integrate PR_NUM ISSUE_NUM [--merge|--squash|--rebase]  Merge PR, close issue, pull main
#   delegate  ISSUE_NUM [--label L ...]   Label bot, audit comment, prune stale refs
#
# All progress goes to stderr, actionable output to stdout.

set -euo pipefail

usage() {
  echo "Usage: scripts/gh-ops.sh <command> [args]" >&2
  echo "Commands: comment, labels, close, search, version, pr-create, pr-merge, pr-close, integrate, delegate" >&2
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

  pr-create)
    HEAD=""
    TITLE=""
    BODY=""
    BODY_FILE=""
    PR_LABELS=()
    while [[ $# -gt 0 ]]; do
      case $1 in
        --head) HEAD="$2"; shift 2 ;;
        --title) TITLE="$2"; shift 2 ;;
        --body) BODY="$2"; shift 2 ;;
        --body-file) BODY_FILE="$2"; shift 2 ;;
        --label) PR_LABELS+=("$2"); shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
      esac
    done
    [ -n "$HEAD" ] || { echo "Error: --head required" >&2; exit 1; }
    [ -n "$TITLE" ] || { echo "Error: --title required" >&2; exit 1; }
    if [ -n "$BODY_FILE" ]; then
      BODY=$(cat "$BODY_FILE")
    elif [ -z "$BODY" ]; then
      BODY="Bot PR for ${HEAD}"
    fi
    ARGS=(--head "$HEAD" --title "$TITLE" --body "$BODY")
    for l in "${PR_LABELS[@]+"${PR_LABELS[@]}"}"; do
      ARGS+=(--label "$l")
    done
    echo "Creating PR: ${TITLE}" >&2
    gh pr create "${ARGS[@]}"
    ;;

  pr-merge)
    [ $# -ge 1 ] || { echo "Error: pr-merge requires PR number" >&2; exit 1; }
    PR_NUM="$1"; shift
    STRATEGY="--squash"
    while [[ $# -gt 0 ]]; do
      case $1 in
        --squash|--merge|--rebase) STRATEGY="$1"; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
      esac
    done
    echo "Merging PR #${PR_NUM} (${STRATEGY#--})" >&2
    # Prune stale worktrees first — agent worktrees hold branch refs and cause
    # --delete-branch to fail on local cleanup (exit 1 even though remote merge
    # and remote branch delete succeed).
    git worktree prune 2>/dev/null
    BRANCH=$(gh pr view "$PR_NUM" --json headRefName --jq '.headRefName' 2>/dev/null || true)
    if [ -n "$BRANCH" ]; then
      # Remove any worktree directory still referencing this branch
      git worktree list --porcelain | awk -v b="$BRANCH" '/^worktree /{p=$2} /^branch /{if($2=="refs/heads/"b) print p}' | while read -r wt; do
        rm -rf "$wt"
      done
      git worktree prune 2>/dev/null
      git branch -D "$BRANCH" 2>/dev/null || true
    fi
    gh pr merge "$PR_NUM" "$STRATEGY" --delete-branch
    ;;

  pr-close)
    [ $# -ge 1 ] || { echo "Error: pr-close requires PR number" >&2; exit 1; }
    PR_NUM="$1"; shift
    BODY=""
    while [[ $# -gt 0 ]]; do
      case $1 in
        --comment|--body) BODY="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
      esac
    done
    echo "Closing PR #${PR_NUM}" >&2
    if [ -n "$BODY" ]; then
      gh pr close "$PR_NUM" --comment "$BODY"
    else
      gh pr close "$PR_NUM"
    fi
    ;;

  integrate)
    # Full post-gate workflow: merge PR, close issue, pull main, prune refs
    [ $# -ge 2 ] || { echo "Error: integrate requires PR_NUM ISSUE_NUM" >&2; exit 1; }
    PR_NUM="$1"; shift
    ISSUE_NUM="$1"; shift
    STRATEGY="--merge"
    while [[ $# -gt 0 ]]; do
      case $1 in
        --squash|--merge|--rebase) STRATEGY="$1"; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
      esac
    done

    # Step 1: Merge PR (includes worktree cleanup)
    echo "==> Merging PR #${PR_NUM} (${STRATEGY#--})" >&2
    git worktree prune 2>/dev/null
    BRANCH=$(gh pr view "$PR_NUM" --json headRefName --jq '.headRefName' 2>/dev/null || true)
    if [ -n "$BRANCH" ]; then
      git worktree list --porcelain | awk -v b="$BRANCH" '/^worktree /{p=$2} /^branch /{if($2=="refs/heads/"b) print p}' | while read -r wt; do
        rm -rf "$wt"
      done
      git worktree prune 2>/dev/null
      git branch -D "$BRANCH" 2>/dev/null || true
    fi
    gh pr merge "$PR_NUM" "$STRATEGY" --delete-branch

    # Step 2: Close issue
    echo "==> Closing issue #${ISSUE_NUM}" >&2
    gh issue close "$ISSUE_NUM" --comment "Fixed in PR #${PR_NUM}" 2>/dev/null || true

    # Step 3: Remove bot label
    gh issue edit "$ISSUE_NUM" --remove-label bot 2>/dev/null || true

    # Step 4: Pull main and prune
    echo "==> Pulling main" >&2
    git checkout main 2>/dev/null || true
    git pull --ff-only 2>/dev/null || true
    git remote prune origin 2>/dev/null || true

    echo "+ Integrated: PR #${PR_NUM} -> issue #${ISSUE_NUM} closed" >&2
    ;;

  delegate)
    # Pre-develop setup: label bot, add audit comment, prune stale refs
    [ $# -ge 1 ] || { echo "Error: delegate requires ISSUE_NUM" >&2; exit 1; }
    ISSUE_NUM="$1"; shift
    EXTRA_LABELS=()
    while [[ $# -gt 0 ]]; do
      case $1 in
        --label) EXTRA_LABELS+=("$2"); shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
      esac
    done

    # Apply bot label (swap from divergence if present)
    echo "==> Labeling issue #${ISSUE_NUM}" >&2
    LABEL_ARGS=(--add-label bot --remove-label divergence)
    for l in "${EXTRA_LABELS[@]+"${EXTRA_LABELS[@]}"}"; do
      LABEL_ARGS+=(--add-label "$l")
    done
    gh issue edit "$ISSUE_NUM" "${LABEL_ARGS[@]}" 2>/dev/null || true

    # Audit trail comment
    echo "==> Adding audit comment" >&2
    gh issue comment "$ISSUE_NUM" --body "Delegated to local develop agent. Branch: bot/issue-${ISSUE_NUM}"

    # Clean stale refs
    git remote prune origin 2>/dev/null || true

    echo "+ Delegated: issue #${ISSUE_NUM} (bot label applied)" >&2
    ;;

  *)
    echo "Unknown command: $CMD" >&2
    usage
    ;;
esac
