#!/usr/bin/env bash
# scripts/integrate-gate.sh — Run fast gate validation on a bot branch
#
# Checks out a bot branch, runs the fast gate tier scripts, reports results.
# Optionally closes the PR/branch on failure.
#
# Fast gate = typecheck + lint + unit tests (NO browser tests).
# Headless Playwright is a separate acceptance step (scripts/test-headless.sh).
#
# When running inside a worktree (agent isolation), stash/restore is skipped
# since the working directory is already isolated.
#
# Usage:
#   scripts/integrate-gate.sh <branch-name>
#   scripts/integrate-gate.sh <branch-name> --close-on-fail --pr <number>
#
# Exit codes:
#   0 — all gates passed
#   1 — gate failed (details printed to stderr)
#   2 — setup error (can't checkout, missing tools)

set -euo pipefail

MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"

BRANCH="${1:-}"
CLOSE_ON_FAIL=false
PR_NUMBER=""
shift || true

while [[ $# -gt 0 ]]; do
  case $1 in
    --close-on-fail) CLOSE_ON_FAIL=true; shift ;;
    --pr) PR_NUMBER="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [ -z "$BRANCH" ]; then
  echo "Usage: scripts/integrate-gate.sh <branch-name> [--close-on-fail] [--pr N]" >&2
  exit 2
fi

cd "$(dirname "$0")/.."

log() { echo "> $*"; }
ok()  { echo "+ $*"; }
err() { echo "! $*" >&2; }

# Track results
TSC_RESULT=""
LINT_RESULT=""
UNIT_RESULT=""
GATE_PASSED=true

# Detect worktree isolation: if we're in a worktree (not the main .git dir),
# skip stash/restore since we have our own working directory.
IS_WORKTREE=false
GIT_DIR=$(git rev-parse --git-dir 2>/dev/null) || true
GIT_COMMON=$(git rev-parse --git-common-dir 2>/dev/null) || true
if [ -n "$GIT_DIR" ] && [ -n "$GIT_COMMON" ] && [ "$GIT_DIR" != "$GIT_COMMON" ]; then
  IS_WORKTREE=true
  log "Running in worktree isolation — skipping stash/restore."
fi

ORIG_BRANCH=""
STASHED=false

if [ "$IS_WORKTREE" = false ]; then
  # Save current state (shared repo mode)
  ORIG_BRANCH=$(git branch --show-current)
  if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    log "Stashing local changes..."
    git stash --include-untracked
    STASHED=true
  fi
fi

cleanup() {
  if [ "$IS_WORKTREE" = false ] && [ -n "$ORIG_BRANCH" ]; then
    log "Returning to ${ORIG_BRANCH}..."
    git checkout "$ORIG_BRANCH" 2>/dev/null || true
    if [ "$STASHED" = true ]; then
      git stash pop 2>/dev/null || true
    fi
  fi
  # Clean up stale worktrees left by agent processes
  git worktree prune 2>/dev/null || true
}
trap cleanup EXIT

# Checkout the branch
log "Fetching and checking out ${BRANCH}..."
if ! git fetch origin "$BRANCH" 2>/dev/null; then
  log "SSH fetch failed, trying HTTPS via gh..."
  REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)
  if [ -n "$REPO" ]; then
    HTTPS_URL="https://github.com/${REPO}.git"
    if ! git fetch "$HTTPS_URL" "$BRANCH" 2>/dev/null; then
      err "Failed to fetch ${BRANCH} via both SSH and HTTPS"
      exit 2
    fi
    if ! git checkout FETCH_HEAD --detach 2>/dev/null; then
      err "Failed to checkout FETCH_HEAD for ${BRANCH}"
      exit 2
    fi
  else
    err "Failed to fetch origin/${BRANCH} and gh CLI unavailable"
    exit 2
  fi
else
  # Use FETCH_HEAD — in worktrees, `git fetch origin <branch>` writes to
  # FETCH_HEAD but doesn't create origin/<branch> tracking ref.
  if ! git checkout FETCH_HEAD --detach 2>/dev/null; then
    err "Failed to checkout origin/${BRANCH}"
    exit 2
  fi
fi

# Gate commands are inlined here, NOT delegated to external scripts.
# After checkout the working directory is the bot branch, which may not have
# the latest tier scripts. The gate must be self-contained.

# Gate 1: TypeScript
log "Gate 1/3: TypeScript typecheck..."
if npx tsc --noEmit 2>&1; then
  TSC_RESULT="pass"
  ok "tsc: pass"
else
  TSC_RESULT="fail"
  err "tsc: FAIL"
  GATE_PASSED=false
fi

# Gate 2: ESLint
log "Gate 2/3: ESLint..."
if npx eslint src/ public/ server/ tests/ 2>&1; then
  LINT_RESULT="pass"
  ok "eslint: pass"
else
  LINT_RESULT="fail"
  err "eslint: FAIL"
  GATE_PASSED=false
fi

# Gate 3: Unit tests (vitest only — no browser tests)
log "Gate 3/3: Unit tests (vitest)..."
if npx vitest run 2>&1; then
  UNIT_RESULT="pass"
  ok "vitest: pass"
else
  UNIT_RESULT="fail"
  err "vitest: FAIL"
  GATE_PASSED=false
fi

# Summary
echo ""
if [ "$GATE_PASSED" = true ]; then
  ok "FAST GATE PASSED: ${BRANCH}"
  ok "  tsc: ${TSC_RESULT} | eslint: ${LINT_RESULT} | vitest: ${UNIT_RESULT}"
else
  err "FAST GATE FAILED: ${BRANCH}"
  err "  tsc: ${TSC_RESULT} | eslint: ${LINT_RESULT} | vitest: ${UNIT_RESULT}"

  # Close PR if requested
  if [ "$CLOSE_ON_FAIL" = true ] && [ -n "$PR_NUMBER" ]; then
    log "Closing PR #${PR_NUMBER}..."
    gh pr close "$PR_NUMBER" --comment "$(cat <<COMMENT
Closing: fast gate failed during integration triage.

**tsc:** ${TSC_RESULT}
**eslint:** ${LINT_RESULT}
**vitest:** ${UNIT_RESULT}

The bot can retry from the issue if the root cause is addressed.
COMMENT
)" 2>/dev/null && ok "PR #${PR_NUMBER} closed." || err "Failed to close PR #${PR_NUMBER}"
  fi

  exit 1
fi
