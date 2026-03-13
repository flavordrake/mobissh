#!/usr/bin/env bash
# scripts/worktree-cleanup.sh — Full cleanup of stale agent artifacts
#
# Removes orphaned worktree directories, worktrees for closed/merged PRs,
# stale local branches (bot/issue-*, worktree-agent-*), and stale remote
# bot branches. Safe to call at any time.
#
# Usage: scripts/worktree-cleanup.sh [--quiet] [--dry-run]
#
# Exit codes:
#   0 — cleanup complete (or nothing to clean)

set -euo pipefail

source "$(dirname "$0")/lib/repo-guard.sh"
ensure_repo_root

QUIET=false
DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --quiet) QUIET=true ;;
    --dry-run) DRY_RUN=true ;;
  esac
done

log() { $QUIET || echo "> $*" >&2; }
act() {
  if $DRY_RUN; then
    log "[dry-run] $*"
    return 0
  fi
  "$@"
}

WORKTREE_DIR=".claude/worktrees"
CLEANED=0

# Phase 1: prune git worktree metadata for entries whose directories are gone
if git worktree prune 2>/dev/null; then
  log "git worktree prune: done"
else
  log "git worktree prune: failed (non-fatal)"
fi

# Phase 2: remove worktree directories (orphaned or for closed PRs)
if [ -d "$WORKTREE_DIR" ]; then
  VALID_WORKTREES=$(git worktree list --porcelain | awk '/^worktree /{print $2}')

  for dir in "$WORKTREE_DIR"/*/; do
    [ -d "$dir" ] || continue
    ABSDIR=$(cd "$dir" && pwd)

    if is_main_repo "$dir"; then
      log "BLOCKED: refusing to delete main repo at $dir"
      continue
    fi

    # Check if git considers it active
    if echo "$VALID_WORKTREES" | grep -qF "$ABSDIR"; then
      # Active worktree — check if its branch still has an open PR
      WT_BRANCH=$(git worktree list --porcelain | awk -v wt="$ABSDIR" '/^worktree /{found=($2==wt)} found && /^branch /{sub("refs/heads/","",$2); print $2; exit}')
      if [ -n "$WT_BRANCH" ]; then
        PR_STATE=$(gh pr list --head "$WT_BRANCH" --json state --jq '.[0].state // empty' 2>/dev/null || true)
        if [ "$PR_STATE" = "MERGED" ] || [ "$PR_STATE" = "CLOSED" ] || [ -z "$PR_STATE" ]; then
          log "removing worktree for ${PR_STATE:-no-PR} branch $WT_BRANCH: $dir"
          act git worktree remove "$ABSDIR" --force 2>/dev/null || act safe_rm_worktree "$dir"
          CLEANED=$((CLEANED + 1))
        else
          log "keeping active worktree (PR open): $dir [$WT_BRANCH]"
        fi
      else
        log "keeping active worktree (no branch detected): $dir"
      fi
    else
      # Orphaned directory — git doesn't know about it
      act safe_rm_worktree "$dir"
      log "removed orphan: $dir"
      CLEANED=$((CLEANED + 1))
    fi
  done

  # Remove empty worktrees directory
  rmdir "$WORKTREE_DIR" 2>/dev/null || true
fi

# Phase 3: prune again after directory removal
git worktree prune 2>/dev/null || true

# Phase 4: delete stale local branches
# bot/issue-* branches where the issue is closed or PR is merged/closed
for branch in $(git branch --list 'bot/issue-*' 2>/dev/null | sed 's/^[+* ]*//' || true); do
  ISSUE_NUM="${branch#bot/issue-}"
  ISSUE_STATE=$(gh issue view "$ISSUE_NUM" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")
  if [ "$ISSUE_STATE" = "CLOSED" ]; then
    log "deleting local branch $branch (issue #$ISSUE_NUM closed)"
    act git branch -D "$branch" 2>/dev/null || true
    CLEANED=$((CLEANED + 1))
  else
    log "keeping local branch $branch (issue #$ISSUE_NUM: $ISSUE_STATE)"
  fi
done

# worktree-agent-* branches are always stale (leftover checkout points from agent isolation)
for branch in $(git branch --list 'worktree-agent-*' 2>/dev/null | sed 's/^[+* ]*//' || true); do
  log "deleting stale agent branch: $branch"
  act git branch -D "$branch" 2>/dev/null || true
  CLEANED=$((CLEANED + 1))
done

# Phase 5: delete stale remote bot branches (merged/closed PRs)
for ref in $(git branch -r --list 'origin/bot/issue-*' 2>/dev/null | sed 's/^[+* ]*//' || true); do
  branch="${ref#origin/}"
  ISSUE_NUM="${branch#bot/issue-}"
  ISSUE_STATE=$(gh issue view "$ISSUE_NUM" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")
  if [ "$ISSUE_STATE" = "CLOSED" ]; then
    log "deleting remote branch $branch (issue #$ISSUE_NUM closed)"
    act git push origin --delete "$branch" 2>/dev/null || true
    CLEANED=$((CLEANED + 1))
  else
    log "keeping remote branch $branch (issue #$ISSUE_NUM: $ISSUE_STATE)"
  fi
done

# Phase 6: prune stale remote tracking refs
git remote prune origin 2>/dev/null || true

if [ $CLEANED -gt 0 ]; then
  log "cleaned $CLEANED item(s)"
else
  log "nothing to clean"
fi
