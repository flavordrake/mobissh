#!/usr/bin/env bash
# scripts/bot-branch.sh — Intent-driven bot branch workflow
#
# Handles the full lifecycle: create branch, stage, commit, push, create PR.
# Replaces ad-hoc git commands that break on CWD drift.
#
# Usage:
#   scripts/bot-branch.sh create ISSUE_NUM                              Create bot/issue-N from main
#   scripts/bot-branch.sh commit ISSUE_NUM "message"                    Merge main, stage, commit, push
#   scripts/bot-branch.sh pr ISSUE_NUM "title"                          Create PR (or report existing)
#   scripts/bot-branch.sh ship ISSUE_NUM "title" "msg"                  All three: create, commit, push, PR
#   scripts/bot-branch.sh rescue ISSUE_NUM WORKTREE_DIR "msg" "title"   Full rescue pipeline from worktree
#
# All operations enforce repo root and guard against CWD drift.

set -euo pipefail

source "$(dirname "$0")/lib/repo-guard.sh"
guard_cwd
ensure_repo_root

log() { echo "> $*" >&2; }
err() { echo "! $*" >&2; }
ok()  { echo "+ $*" >&2; }

[ $# -ge 2 ] || {
  err "Usage: scripts/bot-branch.sh {create|commit|pr|ship|rescue} ISSUE_NUM [args...]"
  exit 1
}

CMD="$1"; shift
ISSUE_NUM="$1"; shift
BRANCH="bot/issue-${ISSUE_NUM}"

_ensure_on_branch() {
  local current
  current="$(git branch --show-current 2>/dev/null || true)"
  if [ "$current" != "$BRANCH" ]; then
    log "switching to $BRANCH"
    git checkout "$BRANCH" 2>/dev/null || {
      err "branch $BRANCH does not exist — create it first"
      exit 1
    }
  fi
}

_create() {
  log "creating $BRANCH from main"
  git checkout main 2>/dev/null || true
  git pull --ff-only 2>/dev/null || true
  git checkout -B "$BRANCH" main
  ok "on $BRANCH (up to date with main)"
}

_commit() {
  local msg="${1:-chore: bot changes for issue #${ISSUE_NUM}}"
  _ensure_on_branch

  # Merge from main before committing to prevent integration drift
  log "merging from main"
  git fetch origin main
  if ! git merge origin/main --no-edit; then
    err "merge from origin/main failed — resolve conflicts and retry"
    exit 1
  fi

  # Stage only test files and fixtures (safe default for emulator test issues)
  local staged=0
  for f in tests/emulator/*.spec.js tests/emulator/fixtures.js; do
    if [ -f "$f" ] && git diff --name-only HEAD -- "$f" | grep -q . 2>/dev/null; then
      git add "$f"
      staged=1
    fi
    # Also add untracked new files
    if [ -f "$f" ] && git ls-files --others --exclude-standard "$f" | grep -q . 2>/dev/null; then
      git add "$f"
      staged=1
    fi
  done

  if [ "$staged" -eq 0 ]; then
    # Fallback: stage all modified/new test files
    git add tests/ 2>/dev/null || true
  fi

  local changes
  changes="$(git diff --cached --stat)"
  if [ -z "$changes" ]; then
    err "nothing to commit"
    exit 1
  fi

  log "committing:"
  echo "$changes" >&2

  git commit -m "$msg

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
  git push -u origin "$BRANCH" 2>&1
  ok "committed and pushed to $BRANCH"
}

_pr() {
  local title="${1:-chore: bot fix for #${ISSUE_NUM}}"

  # Check for existing PR
  local existing
  existing="$(gh pr list --head "$BRANCH" --json number,url --jq '.[0].url // empty' 2>/dev/null || true)"
  if [ -n "$existing" ]; then
    ok "PR already exists: $existing"
    echo "$existing"
    return 0
  fi

  log "creating PR: $title"
  scripts/gh-ops.sh pr-create \
    --head "$BRANCH" \
    --title "$title" \
    --body "Bot fix for #${ISSUE_NUM}. Closes #${ISSUE_NUM}." \
    --label bot
}

_rescue() {
  local wt_dir="${1:-}"
  local msg="${2:-chore: rescue for issue #${ISSUE_NUM}}"
  local title="${3:-chore: rescue fix for #${ISSUE_NUM}}"

  [ -n "$wt_dir" ] || { err "rescue requires WORKTREE_DIR"; exit 1; }
  [ -d "$wt_dir" ] || { err "worktree not found: $wt_dir"; exit 1; }

  # Resolve to absolute path
  wt_dir="$(cd "$wt_dir" && pwd)"

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
  MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
  mkdir -p "$MOBISSH_TMPDIR"
  local copy_list="$MOBISSH_TMPDIR/rescue-files-${ISSUE_NUM}.txt"
  (cd "$wt_dir" && git status --short | awk '{print $2}') > "$copy_list"

  # Create branch from main (resets any previous state)
  _create

  # Copy files from worktree to repo
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
    git checkout main 2>/dev/null
    exit 1
  fi

  ok "rescued $count files from worktree to $BRANCH"

  # Commit and push (merge-from-main already done in _create via pull)
  local changes
  changes="$(git diff --cached --stat)"
  if [ -z "$changes" ]; then
    err "nothing staged after rescue"
    exit 1
  fi

  log "committing:"
  echo "$changes" >&2

  git commit -m "$msg

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
  git push -u origin "$BRANCH" 2>&1
  ok "pushed $BRANCH"

  # Create PR
  _pr "$title"
}

case "$CMD" in
  create)
    _create
    ;;
  commit)
    MSG="${1:-chore: bot changes for issue #${ISSUE_NUM}}"
    _commit "$MSG"
    ;;
  pr)
    TITLE="${1:-chore: bot fix for #${ISSUE_NUM}}"
    _pr "$TITLE"
    ;;
  ship)
    TITLE="${1:-chore: bot fix for #${ISSUE_NUM}}"
    MSG="${2:-$TITLE}"
    _create
    _commit "$MSG"
    _pr "$TITLE"
    ;;
  rescue)
    WT_DIR="${1:-}"
    MSG="${2:-chore: rescue for issue #${ISSUE_NUM}}"
    TITLE="${3:-chore: rescue fix for #${ISSUE_NUM}}"
    _rescue "$WT_DIR" "$MSG" "$TITLE"
    ;;
  *)
    err "Unknown command: $CMD (use create|commit|pr|ship|rescue)"
    exit 1
    ;;
esac
