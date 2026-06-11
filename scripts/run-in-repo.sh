#!/usr/bin/env bash
# scripts/run-in-repo.sh — Run a command from the MAIN repo root
# Usage: scripts/run-in-repo.sh <command> [args...]
# Solves CWD drift when Claude Code process CWD is outside the repo.
#
# Worktree trap (hit 2026-06-11, mis-shipped +57 onto a bot branch): when the
# process CWD has drifted INTO an agent worktree, a relative
# `scripts/run-in-repo.sh` resolves to the WORKTREE'S copy of this script,
# whose dirname/.. is the worktree root — so "run in repo" silently ran in the
# worktree. Strip any `.claude/worktrees/<agent>` segment so this script always
# lands in the MAIN checkout regardless of which copy was invoked.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "$REPO_ROOT" in
  */.claude/worktrees/*)
    REPO_ROOT="${REPO_ROOT%%/.claude/worktrees/*}"
    ;;
esac
cd "$REPO_ROOT"
exec "$@"
