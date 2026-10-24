#!/usr/bin/env bash
# scripts/worktree-prune-merged.sh — remove agent worktrees whose work is already
# on origin/main, and nothing else. Safe to run while agents are active.
#
# worktree-cleanup.sh is the release-time sweep: it force-removes every worktree
# without an open PR (all `worktree-agent-*` checkouts, merged or not) and
# deletes branches. This is the narrow tool for a disk-pressure ask: it keeps
# a worktree when ANY of these hold:
#   - HEAD is not an ancestor of origin/main (unmerged or squash-only work)
#   - it has a tracked change other than the build-runner hook in
#     scripts/flutter-cmd.sh (homelab injects that line into every checkout)
#   - it has untracked, non-ignored files (uncommitted work, test-history)
#   - a live process has its CWD inside it (an agent or build in flight)
# Branches are never deleted; `git worktree remove` is the only removal.
#
# Usage: scripts/worktree-prune-merged.sh [--dry-run]
# Prints one line per worktree (remove/keep + reason) and the GB freed.

set -euo pipefail

source "$(dirname "$0")/lib/repo-guard.sh"
ensure_repo_root

DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    *) echo "Usage: $0 [--dry-run]" >&2; exit 2 ;;
  esac
done

ALLOWED_DIRTY="scripts/flutter-cmd.sh"

if ! git fetch -q origin main; then
  echo "> fetch origin main failed; judging against the existing origin/main" >&2
fi

avail_mb() { df --output=avail -BM "$REPO_ROOT" | tail -n 1 | tr -dc '0-9'; }

# CWDs of every live process, to spot a worktree something is running in.
live_cwds() {
  local p
  for p in /proc/[0-9]*/cwd; do
    readlink "$p" 2>/dev/null || continue
  done
}

before=$(avail_mb)
cwds=$(live_cwds | sort -u)
removed=0
kept=0

for wt in "$REPO_ROOT"/.claude/worktrees/agent-*; do
  [ -d "$wt" ] || continue
  name=$(basename "$wt")
  reason=""
  head=$(git -C "$wt" rev-parse -q --verify HEAD 2>/dev/null || true)
  if [ -z "$head" ]; then
    reason="no HEAD"
  elif ! git merge-base --is-ancestor "$head" origin/main; then
    reason="not on origin/main"
  else
    dirty=$(git -C "$wt" status --porcelain --untracked-files=no | awk '{print $2}' | grep -vxF "$ALLOWED_DIRTY" || true)
    untracked=$(git -C "$wt" ls-files --others --exclude-standard | head -n 1)
    if [ -n "$dirty" ]; then
      reason="tracked changes: $(echo "$dirty" | head -n 1)"
    elif [ -n "$untracked" ]; then
      reason="untracked: $untracked"
    elif printf '%s\n' "$cwds" | grep -qE "^$(printf '%s' "$wt" | sed 's/[.[\*^$]/\\&/g')(/|$)"; then
      reason="a process is running in it"
    fi
  fi

  if [ -n "$reason" ]; then
    echo "keep   $name ($reason)"
    kept=$((kept + 1))
    continue
  fi
  echo "remove $name"
  if ! $DRY_RUN; then
    if ! git worktree remove --force "$wt"; then
      echo "  ! git worktree remove failed for $name; left in place" >&2
      continue
    fi
  fi
  removed=$((removed + 1))
done

git worktree prune
after=$(avail_mb)
freed=$(( after - before ))
if $DRY_RUN; then
  echo "> dry run: would remove $removed, keep $kept"
else
  echo "> removed $removed, kept $kept; freed $(awk -v m="$freed" 'BEGIN{printf "%.1f", m/1024}')G ($(( after / 1024 ))G free)"
fi
