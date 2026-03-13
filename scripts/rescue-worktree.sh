#!/usr/bin/env bash
# scripts/rescue-worktree.sh — Extract work from a stalled agent worktree
#
# When a develop agent stalls before committing, this script safely copies
# its changes to the main repo on the correct bot branch.
#
# Usage:
#   scripts/rescue-worktree.sh ISSUE_NUM              Auto-find worktree, rescue, clean up
#   scripts/rescue-worktree.sh ISSUE_NUM WORKTREE_DIR  Rescue from specific worktree
#   scripts/rescue-worktree.sh --list                  List all worktrees with status
#
# Replaces the ad-hoc: cp from worktree, manually create branch, commit, push

set -euo pipefail

source "$(dirname "$0")/lib/repo-guard.sh"
guard_cwd
ensure_repo_root

MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
mkdir -p "$MOBISSH_TMPDIR"

log() { echo "> $*" >&2; }
err() { echo "! $*" >&2; }
ok()  { echo "+ $*" >&2; }

_list_worktrees() {
  local wt_dir="$REPO_ROOT/.claude/worktrees"
  if [ ! -d "$wt_dir" ]; then
    log "no worktrees directory"
    return 0
  fi

  echo "Worktree                        | Branch          | Modified files"
  echo "---                             | ---             | ---"
  for dir in "$wt_dir"/*/; do
    [ -d "$dir" ] || continue
    local name
    name="$(basename "$dir")"
    local branch="(detached)"
    local modified=0

    if [ -d "$dir/.git" ] || [ -f "$dir/.git" ]; then
      branch="$(cd "$dir" && git branch --show-current 2>/dev/null || echo "(detached)")"
      modified="$(cd "$dir" && git status --short 2>/dev/null | wc -l)"
    fi
    printf "%-32s| %-16s| %s files\n" "$name" "$branch" "$modified"
  done
}

_find_worktree() {
  local issue_num="$1"
  local wt_dir="$REPO_ROOT/.claude/worktrees"
  [ -d "$wt_dir" ] || { err "no worktrees directory"; exit 1; }

  # Find worktrees with modifications
  local found=""
  for dir in "$wt_dir"/*/; do
    [ -d "$dir" ] || continue
    local modified
    modified="$(cd "$dir" && git status --short 2>/dev/null | wc -l)"
    if [ "$modified" -gt 0 ]; then
      # Check if this worktree is on the right branch or has relevant files
      found="$dir"
    fi
  done

  if [ -z "$found" ]; then
    err "no worktree found with uncommitted changes"
    exit 1
  fi
  echo "$found"
}

_rescue() {
  local issue_num="$1"
  local wt_dir="$2"
  local branch="bot/issue-${issue_num}"

  if [ ! -d "$wt_dir" ]; then
    err "worktree not found: $wt_dir"
    exit 1
  fi

  # List modified files in worktree
  log "scanning worktree: $wt_dir"
  local files
  files="$(cd "$wt_dir" && git status --short 2>/dev/null)"
  if [ -z "$files" ]; then
    err "no modified or new files in worktree"
    exit 1
  fi
  echo "$files" >&2

  # Save file list for copying
  local copy_list="$MOBISSH_TMPDIR/rescue-files-${issue_num}.txt"
  (cd "$wt_dir" && git status --short | awk '{print $2}') > "$copy_list"

  # Create branch in main repo
  ensure_repo_root
  git checkout main 2>/dev/null || true
  git pull --ff-only 2>/dev/null || true
  git checkout -B "$branch" main
  log "on $branch"

  # Copy files from worktree to main repo
  local count=0
  while IFS= read -r file; do
    local src="$wt_dir/$file"
    local dst="$REPO_ROOT/$file"
    if [ -f "$src" ]; then
      mkdir -p "$(dirname "$dst")"
      cp "$src" "$dst"
      git add "$file"
      count=$((count + 1))
      log "rescued: $file"
    fi
  done < "$copy_list"

  if [ "$count" -eq 0 ]; then
    err "no files to rescue"
    git checkout main
    exit 1
  fi

  ok "rescued $count files from worktree to $branch"
  echo "Next: scripts/bot-branch.sh commit $issue_num \"your commit message\""
}

# Parse args
case "${1:-}" in
  --list|-l)
    _list_worktrees
    exit 0
    ;;
  "")
    err "Usage: scripts/rescue-worktree.sh ISSUE_NUM [WORKTREE_DIR]"
    err "       scripts/rescue-worktree.sh --list"
    exit 1
    ;;
esac

ISSUE_NUM="$1"; shift
WT_DIR="${1:-}"

if [ -z "$WT_DIR" ]; then
  WT_DIR="$(_find_worktree "$ISSUE_NUM")"
fi

# Resolve to absolute path
WT_DIR="$(cd "$WT_DIR" && pwd)"

_rescue "$ISSUE_NUM" "$WT_DIR"
