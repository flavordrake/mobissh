#!/usr/bin/env bash
# scripts/worktree-cleanup.sh — Prune stale agent worktrees
#
# Removes orphaned worktree directories in .claude/worktrees/ and prunes
# git worktree metadata. Safe to call at any time — skips worktrees that
# are still actively checked out.
#
# Usage: scripts/worktree-cleanup.sh [--quiet]
#
# Exit codes:
#   0 — cleanup complete (or nothing to clean)

set -euo pipefail

cd "$(dirname "$0")/.."

QUIET=false
[[ "${1:-}" == "--quiet" ]] && QUIET=true

log() { $QUIET || echo "> $*"; }

WORKTREE_DIR=".claude/worktrees"
CLEANED=0

# Phase 1: prune git worktree metadata for entries whose directories are gone
if git worktree prune 2>/dev/null; then
  log "git worktree prune: done"
else
  log "git worktree prune: failed (non-fatal)"
fi

# Phase 2: remove orphaned worktree directories
# A directory is orphaned if it exists on disk but git doesn't list it as a valid worktree.
if [ -d "$WORKTREE_DIR" ]; then
  # Build list of valid worktree paths from git
  VALID_WORKTREES=$(git worktree list --porcelain | awk '/^worktree /{print $2}')

  for dir in "$WORKTREE_DIR"/*/; do
    [ -d "$dir" ] || continue
    ABSDIR=$(cd "$dir" && pwd)

    if echo "$VALID_WORKTREES" | grep -qF "$ABSDIR"; then
      log "keeping active worktree: $dir"
    else
      rm -rf "$dir"
      log "removed orphan: $dir"
      CLEANED=$((CLEANED + 1))
    fi
  done

  # Remove empty worktrees directory
  rmdir "$WORKTREE_DIR" 2>/dev/null || true
fi

# Phase 3: prune again after directory removal
git worktree prune 2>/dev/null || true

# Phase 4: prune stale remote tracking refs
git remote prune origin 2>/dev/null || true

if [ $CLEANED -gt 0 ]; then
  log "cleaned $CLEANED orphaned worktree(s)"
else
  log "no orphaned worktrees found"
fi
