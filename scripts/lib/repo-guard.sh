#!/usr/bin/env bash
# scripts/lib/repo-guard.sh — Shared repo safety functions
#
# Source this from any script that touches git state:
#   source "$(dirname "$0")/lib/repo-guard.sh"
#
# Provides:
#   REPO_ROOT         — absolute path to the real repo (not a worktree)
#   ensure_repo_root  — cd to REPO_ROOT, abort if repo is missing
#   is_main_repo      — test if a path is the main repo (not a worktree)
#   safe_rm_worktree  — rm -rf a worktree path ONLY if it's not the main repo
#   guard_cwd         — detect CWD drift and fix it

# Resolve the real repo root (works from scripts/lib/, scripts/, or repo root)
# Handles both the main repo (.git is a directory) and worktrees (.git is a file)
_resolve_repo_root() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # script_dir is scripts/lib/, so repo is ../..
  local candidate="$script_dir/../.."
  candidate="$(cd "$candidate" && pwd)"

  # Main repo: .git is a directory
  if [ -d "$candidate/.git" ]; then
    echo "$candidate"
    return 0
  fi

  # Worktree: .git is a file pointing to the main repo's git dir
  if [ -f "$candidate/.git" ]; then
    local gitdir
    gitdir="$(grep '^gitdir:' "$candidate/.git" | sed 's/^gitdir: //')"
    # gitdir is like /path/to/main/.git/worktrees/<name>
    # Navigate up three levels: worktrees/<name> -> worktrees -> .git -> main
    local main_repo
    main_repo="$(cd "$gitdir/../../.." 2>/dev/null && pwd)" || {
      echo "FATAL: repo-guard cannot resolve main repo from gitdir: $gitdir" >&2
      return 1
    }
    if [ -d "$main_repo/.git" ]; then
      echo "$main_repo"
      return 0
    fi
  fi

  echo "FATAL: repo-guard cannot find .git at $candidate" >&2
  return 1
}

REPO_ROOT="$(_resolve_repo_root)"

# Verify the main repo exists and cd to it
ensure_repo_root() {
  if [ ! -d "$REPO_ROOT/.git" ]; then
    echo "FATAL: main repo missing at $REPO_ROOT — was it deleted?" >&2
    exit 99
  fi
  cd "$REPO_ROOT"
}

# Test if an absolute path is the main repo root (returns 0=yes, 1=no)
is_main_repo() {
  local path="$1"
  local abs_path
  abs_path="$(cd "$path" 2>/dev/null && pwd)" || return 1
  [ "$abs_path" = "$REPO_ROOT" ]
}

# Safe rm -rf that refuses to delete the main repo
# Usage: safe_rm_worktree /path/to/worktree
safe_rm_worktree() {
  local target="$1"

  if [ ! -d "$target" ]; then
    return 0  # already gone
  fi

  local abs_target
  abs_target="$(cd "$target" && pwd)"

  # NEVER delete the main repo
  if [ "$abs_target" = "$REPO_ROOT" ]; then
    echo "BLOCKED: refusing to delete main repo at $abs_target" >&2
    return 1
  fi

  # NEVER delete anything outside .claude/worktrees/
  case "$abs_target" in
    "$REPO_ROOT/.claude/worktrees/"*)
      rm -rf "$target"
      ;;
    *)
      echo "BLOCKED: refusing to delete $abs_target (not inside .claude/worktrees/)" >&2
      return 1
      ;;
  esac
}

# Detect and fix CWD drift (CWD is inside a deleted or stale worktree)
guard_cwd() {
  if ! pwd >/dev/null 2>&1; then
    echo "CWD drift detected: current directory no longer exists" >&2
    ensure_repo_root
    return 0
  fi

  local cwd
  cwd="$(pwd)"

  # If CWD is inside a worktree, move to repo root
  case "$cwd" in
    "$REPO_ROOT/.claude/worktrees/"*)
      echo "CWD drift detected: inside worktree $cwd" >&2
      ensure_repo_root
      ;;
  esac
}
