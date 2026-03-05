#!/usr/bin/env bash
# scripts/integrate-merge.sh — Merge a bot branch: create PR, squash merge, close issue, update labels
#
# Usage:
#   scripts/integrate-merge.sh <branch-name>
#
# Branch pattern: claude/issue-{N}-{date}-{time}
# Outputs to stdout: "Merged: #N <title> via PR #P"

set -euo pipefail

LOGFILE="/tmp/integrate-merge.log"

BRANCH="${1:-}"
if [ -z "$BRANCH" ]; then
  echo "Usage: scripts/integrate-merge.sh <branch-name>" >&2
  exit 1
fi

cd "$(dirname "$0")/.."

log() { echo "> $*" >&2; echo "> $*" >> "$LOGFILE"; }
ok()  { echo "+ $*" >&2; echo "+ $*" >> "$LOGFILE"; }
err() { echo "! $*" >&2; echo "! $*" >> "$LOGFILE"; }

log "integrate-merge: $BRANCH"

# Extract issue number from branch name pattern claude/issue-{N}-{date}-{time}
issue_num=$(echo "$BRANCH" | sed 's|.*issue-\([0-9]*\)-.*|\1|')
if [ -z "$issue_num" ] || [ "$issue_num" = "$BRANCH" ]; then
  err "Could not extract issue number from branch: $BRANCH"
  exit 1
fi
log "Issue: #${issue_num}"

# Fetch issue title
issue_title=$(gh issue view "$issue_num" --json title --jq '.title' 2>/dev/null)
if [ -z "$issue_title" ]; then
  err "Could not fetch title for issue #${issue_num}"
  exit 1
fi
log "Title: ${issue_title}"

# Check if PR already exists for this branch
log "Checking for existing PR..."
pr_num=$(gh pr list --head "$BRANCH" --json number --jq '.[0].number // empty' 2>/dev/null)

if [ -z "$pr_num" ]; then
  log "No PR found — creating..."
  pr_url=$(gh pr create \
    --head "$BRANCH" \
    --base main \
    --title "$issue_title" \
    --body "$(printf 'Bot fix for #%s\n\nCloses #%s' "$issue_num" "$issue_num")")
  pr_num=$(echo "$pr_url" | grep -oE '[0-9]+$')
  log "Created PR #${pr_num}: ${pr_url}"
else
  log "Found existing PR #${pr_num}"
fi

# Merge with squash and delete branch
log "Merging PR #${pr_num} with squash..."
gh pr merge "$pr_num" --squash --delete-branch
ok "Merged PR #${pr_num}"

# Remove bot label from issue
log "Removing bot label from #${issue_num}..."
scripts/gh-ops.sh labels "$issue_num" --rm bot

# Close issue with comment referencing PR
scripts/gh-ops.sh close "$issue_num" --comment "Fixed in PR #${pr_num}"

echo "Merged: #${issue_num} ${issue_title} via PR #${pr_num}"
