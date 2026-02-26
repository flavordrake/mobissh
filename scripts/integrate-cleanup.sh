#!/usr/bin/env bash
# scripts/integrate-cleanup.sh — Delete bot branches and comment on over-attempted issues
#
# Takes integrate-discover.sh JSON on stdin (or --file), deletes branches for
# issues marked "reject" (>2 attempts), and comments on the GitHub issue.
#
# Usage:
#   bash scripts/integrate-discover.sh | bash scripts/integrate-cleanup.sh
#   bash scripts/integrate-cleanup.sh --file candidates.json
#   bash scripts/integrate-cleanup.sh --issue 125  # clean up a specific issue
#
# Options:
#   --file FILE     Read candidate JSON from file instead of stdin
#   --issue NUM     Clean up branches for a specific issue number
#   --dry-run       Show what would be done without doing it
#   --all           Delete ALL bot branches (not just reject-risk ones)

set -euo pipefail

REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
DRY_RUN=false
SPECIFIC_ISSUE=""
CLEAN_ALL=false
INPUT_FILE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY_RUN=true; shift ;;
    --issue) SPECIFIC_ISSUE="$2"; shift 2 ;;
    --all) CLEAN_ALL=true; shift ;;
    --file) INPUT_FILE="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

log() { printf '\033[36m> %s\033[0m\n' "$*"; }
ok()  { printf '\033[32m+ %s\033[0m\n' "$*"; }
err() { printf '\033[31m! %s\033[0m\n' "$*" >&2; }

delete_branch() {
  local branch="$1"
  if [ "$DRY_RUN" = true ]; then
    log "[dry-run] Would delete: $branch"
  else
    if gh api -X DELETE "repos/${REPO}/git/refs/heads/${branch}" 2>/dev/null; then
      ok "Deleted: $branch"
    else
      err "Failed to delete: $branch"
    fi
  fi
}

comment_issue() {
  local issue_num="$1"
  local attempts="$2"
  local title="$3"

  local body="Bot attempted ${attempts} fixes for this issue (branches deleted during integration triage). None converged on a working solution or opened a PR.

This issue needs human scoping before the bot can help. Consider:
- Breaking the issue into smaller, more specific tasks
- Adding reproduction steps or a visual spec
- Debugging on a real device to capture the event/render sequence

Removing \`@claude\` assignment — re-add after re-scoping."

  if [ "$DRY_RUN" = true ]; then
    log "[dry-run] Would comment on #${issue_num}: ${attempts} failed attempts"
  else
    gh issue comment "$issue_num" --body "$body"
    ok "Commented on #${issue_num}"
  fi
}

# Handle --issue mode (no JSON input needed)
if [ -n "$SPECIFIC_ISSUE" ]; then
  branches=$(gh api "repos/${REPO}/branches" --paginate --jq '.[].name' \
    | grep "^claude/issue-${SPECIFIC_ISSUE}-" || true)
  if [ -z "$branches" ]; then
    log "No bot branches found for issue #${SPECIFIC_ISSUE}"
    exit 0
  fi
  count=$(echo "$branches" | wc -l)
  log "Found ${count} branch(es) for issue #${SPECIFIC_ISSUE}"
  for branch in $branches; do
    delete_branch "$branch"
  done
  exit 0
fi

# Read JSON input
if [ -n "$INPUT_FILE" ]; then
  candidates=$(cat "$INPUT_FILE")
elif [ ! -t 0 ]; then
  candidates=$(cat)
else
  err "No input. Pipe integrate-discover.sh output or use --file/--issue."
  exit 1
fi

# Process candidates
echo "$candidates" | jq -c '.[]' | while read -r entry; do
  issue_num=$(echo "$entry" | jq -r '.issue')
  risk=$(echo "$entry" | jq -r '.risk')
  attempts=$(echo "$entry" | jq -r '.attempts')
  title=$(echo "$entry" | jq -r '.title')

  if [ "$CLEAN_ALL" = true ] || [ "$risk" = "reject" ]; then
    log "Issue #${issue_num}: ${title} (${attempts} attempts, risk=${risk})"

    # Delete all branches for this issue
    echo "$entry" | jq -r '.branches[].name' | while read -r branch; do
      delete_branch "$branch"
    done

    # Comment on the issue if it's a reject (not just general cleanup)
    if [ "$risk" = "reject" ]; then
      comment_issue "$issue_num" "$attempts" "$title"
    fi
  fi
done

log "Cleanup complete."
