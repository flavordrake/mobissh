#!/usr/bin/env bash
# scripts/integrate-gate.sh — Run fast gate validation on a bot branch
#
# Checks out a bot branch, runs the fast gate tier scripts, reports results.
# Optionally closes the PR/branch on failure.
#
# Gate tiers:
#   1. scripts/native-fast-gate.sh — bash rule tests + the node:test infra tests
#      + flutter analyze + the flutter unit suite
#   2. ESLint over the remaining JS (server, feedback service, static scripts)
#   3. Test coverage check (source changes must include test changes)
#
# #1205: tiers 1-3 used to be tsc / eslint / vitest over the PWA, and tier 5 ran
# headless Playwright when a PR touched PWA UI files. The PWA is retired; the
# native gate is what actually guards a bot branch now. The on-emulator
# integration tier stays OUT of this gate — it needs a leased device.
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

source "$(dirname "$0")/lib/repo-guard.sh"
guard_cwd

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
NATIVE_RESULT=""
LINT_RESULT=""
COVERAGE_RESULT=""
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
  # Worktree cleanup deferred to release — running it here kills active agents
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

# Install server dependencies (node_modules is gitignored, missing in worktrees)
if [ -f server/package.json ] && [ ! -d server/node_modules ]; then
  log "Installing server dependencies..."
  npm --prefix server install --ignore-scripts 2>&1
fi

# Gate 1: the native fast gate (relative path — this runs inside the checked-out
# branch's own tree, per .claude/rules/agents.md #537)
log "Gate 1/3: native fast gate..."
if scripts/native-fast-gate.sh 2>&1; then
  NATIVE_RESULT="pass"
  ok "native gate: pass"
else
  NATIVE_RESULT="fail"
  err "native gate: FAIL"
  GATE_PASSED=false
fi

# Gate 2: ESLint over the JS that is left
log "Gate 2/3: ESLint..."
if npx eslint server/ server-feedback/ public/ test/ 2>&1; then
  LINT_RESULT="pass"
  ok "eslint: pass"
else
  LINT_RESULT="fail"
  err "eslint: FAIL"
  GATE_PASSED=false
fi

# Gate 3: Test coverage check — source changes must include test changes
log "Gate 3/3: Test coverage check..."
CHANGED_SRC=$(git diff --name-only origin/main -- 'native/lib/*' 'server/*.js' 'server-feedback/*.js' 2>/dev/null || true)
CHANGED_TESTS=$(git diff --name-only origin/main -- 'native/test/*' 'native/integration_test/*' 'test/*' 2>/dev/null || true)
CHANGED_INFRA=$(git diff --name-only origin/main -- 'scripts/*' '.claude/*' '*.json' '*.md' 2>/dev/null || true)
CHANGED_SRC_COUNT=$(echo "$CHANGED_SRC" | grep -c '[^[:space:]]' || true)
CHANGED_TESTS_COUNT=$(echo "$CHANGED_TESTS" | grep -c '[^[:space:]]' || true)

if [ "$CHANGED_SRC_COUNT" -gt 0 ] && [ "$CHANGED_TESTS_COUNT" -eq 0 ]; then
  COVERAGE_RESULT="fail"
  err "coverage: FAIL — ${CHANGED_SRC_COUNT} source file(s) changed, 0 test files changed"
  err "  Changed: ${CHANGED_SRC}"
  GATE_PASSED=false
else
  COVERAGE_RESULT="pass"
  if [ "$CHANGED_SRC_COUNT" -gt 0 ]; then
    ok "coverage: pass (${CHANGED_SRC_COUNT} src, ${CHANGED_TESTS_COUNT} test files)"
  else
    ok "coverage: pass (no source changes or exempt)"
  fi
fi

# Summary
echo ""
if [ "$GATE_PASSED" = true ]; then
  ok "GATE PASSED: ${BRANCH}"
  ok "  native: ${NATIVE_RESULT} | eslint: ${LINT_RESULT} | coverage: ${COVERAGE_RESULT}"
else
  err "GATE FAILED: ${BRANCH}"
  err "  native: ${NATIVE_RESULT} | eslint: ${LINT_RESULT} | coverage: ${COVERAGE_RESULT}"

  # Close PR if requested
  if [ "$CLOSE_ON_FAIL" = true ] && [ -n "$PR_NUMBER" ]; then
    log "Closing PR #${PR_NUMBER}..."
    gh pr close "$PR_NUMBER" --comment "$(cat <<COMMENT
Closing: gate failed during integration triage.

**native gate:** ${NATIVE_RESULT}
**eslint:** ${LINT_RESULT}
**coverage:** ${COVERAGE_RESULT}

The bot can retry from the issue if the root cause is addressed.
COMMENT
)" 2>/dev/null && ok "PR #${PR_NUMBER} closed." || err "Failed to close PR #${PR_NUMBER}"
  fi

  exit 1
fi
