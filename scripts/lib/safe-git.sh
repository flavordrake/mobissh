#!/usr/bin/env bash
# scripts/lib/safe-git.sh — Git safety wrapper
#
# Source this in scripts or shell sessions to catch dangerous git patterns.
# Does NOT replace git — wraps it with guards for known footguns.
#
# Usage:
#   source scripts/lib/safe-git.sh
#   safe_git checkout main          # guards CWD first
#   safe_git worktree remove ...    # guards against main repo deletion
#
# Or install as shell function:
#   eval "$(scripts/lib/safe-git.sh --install)"

set -euo pipefail

# If sourced with --install, emit function definition for .bashrc/.zshrc
if [[ "${1:-}" == "--install" ]]; then
  cat <<'INSTALL_EOF'
# MobiSSH git safety wrapper — add to .bashrc or .zshrc
safe_git() {
  local repo_root="/home/dev/workspace/mobissh"

  # Guard 1: CWD drift detection
  if ! pwd >/dev/null 2>&1; then
    echo "! CWD drift: current directory deleted. Returning to repo root." >&2
    cd "$repo_root"
  fi

  # Guard 2: rm -rf in worktree context
  case "${1:-} ${2:-}" in
    "worktree remove"|"worktree prune")
      echo "> safe_git: running from $repo_root (guarded)" >&2
      cd "$repo_root"
      ;;
  esac

  # Guard 3: checkout after worktree operations
  case "${1:-}" in
    checkout)
      local cwd
      cwd="$(pwd 2>/dev/null || echo DRIFTED)"
      case "$cwd" in
        */\.claude/worktrees/*)
          echo "! CWD is inside a worktree ($cwd). Moving to repo root first." >&2
          cd "$repo_root"
          ;;
        DRIFTED)
          echo "! CWD deleted. Moving to repo root first." >&2
          cd "$repo_root"
          ;;
      esac
      ;;
  esac

  # Guard 4: warn on raw rm -rf of worktree paths
  # (This function won't catch raw rm, but the repo-guard.sh handles that)

  command git "$@"
}
INSTALL_EOF
  exit 0
fi

# When sourced directly, provide safe_git as a function
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_LIB="$SCRIPT_DIR/repo-guard.sh"

if [ -f "$GUARD_LIB" ]; then
  source "$GUARD_LIB"
fi

safe_git() {
  # Guard CWD before any git operation
  if [ "$(type -t guard_cwd)" = "function" ]; then
    guard_cwd
  fi

  case "${1:-}" in
    checkout)
      if [ "$(type -t ensure_repo_root)" = "function" ]; then
        ensure_repo_root
      fi
      ;;
  esac

  command git "$@"
}
