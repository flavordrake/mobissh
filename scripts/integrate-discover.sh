#!/usr/bin/env bash
# scripts/integrate-discover.sh — Discover bot PR integration candidates
#
# Lists all Claude bot branches, groups by issue, counts attempts,
# and outputs a JSON summary for triage.
#
# Usage: bash scripts/integrate-discover.sh
# Output: JSON array to stdout
#
# Each entry:
#   { issue, title, attempts, branches: [{name, additions, deletions, files, ahead}], risk }
#
# Risk levels:
#   reject  — >2 attempts (know-when-to-quit)
#   low     — single file, <50 lines
#   medium  — multi-file within one module, or new code paths only
#   high    — core code, >200 lines, server changes

set -euo pipefail

REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')

# Get all bot branches
BRANCHES=$(gh api "repos/${REPO}/branches" --paginate --jq '.[].name' | grep '^claude/issue-' || true)

if [ -z "$BRANCHES" ]; then
  echo "[]"
  exit 0
fi

# Group branches by issue number
declare -A ISSUE_BRANCHES
for branch in $BRANCHES; do
  issue_num=$(echo "$branch" | grep -oP 'issue-\K\d+')
  if [ -n "${ISSUE_BRANCHES[$issue_num]:-}" ]; then
    ISSUE_BRANCHES[$issue_num]="${ISSUE_BRANCHES[$issue_num]} $branch"
  else
    ISSUE_BRANCHES[$issue_num]="$branch"
  fi
done

# Build JSON output
echo "["
first=true
for issue_num in $(echo "${!ISSUE_BRANCHES[@]}" | tr ' ' '\n' | sort -n); do
  branches="${ISSUE_BRANCHES[$issue_num]}"
  attempt_count=$(echo "$branches" | wc -w)

  # Get issue title
  title=$(gh issue view "$issue_num" --json title --jq '.title' 2>/dev/null || echo "unknown")

  # Determine risk
  if [ "$attempt_count" -gt 2 ]; then
    risk="reject"
  else
    # Use the latest branch (last in sorted order) for stats
    latest=$(echo "$branches" | tr ' ' '\n' | sort | tail -1)
    stats=$(gh api "repos/${REPO}/compare/main...${latest}" \
      --jq '{ahead: .ahead_by, additions: ([.files[].additions] | add), deletions: ([.files[].deletions] | add), files: (.files | length), filenames: [.files[].filename]}' 2>/dev/null || echo '{}')

    ahead=$(echo "$stats" | jq '.ahead // 0')
    additions=$(echo "$stats" | jq '.additions // 0')
    deletions=$(echo "$stats" | jq '.deletions // 0')
    file_count=$(echo "$stats" | jq '.files // 0')
    total_lines=$((additions + deletions))

    # Check for high-risk file patterns
    has_server=$(echo "$stats" | jq '[.filenames[] | select(startswith("server/"))] | length > 0')
    has_vault=$(echo "$stats" | jq '[.filenames[] | select(contains("vault") or contains("crypto"))] | length > 0')

    if [ "$ahead" -eq 0 ]; then
      risk="skip"
    elif [ "$has_server" = "true" ] || [ "$has_vault" = "true" ] || [ "$total_lines" -gt 200 ]; then
      risk="high"
    elif [ "$file_count" -le 1 ] && [ "$total_lines" -lt 50 ]; then
      risk="low"
    elif [ "$file_count" -le 3 ] && [ "$total_lines" -lt 100 ]; then
      risk="medium"
    else
      risk="high"
    fi
  fi

  # Build branch details as proper JSON
  branch_json="[]"
  for branch in $branches; do
    bstats=$(gh api "repos/${REPO}/compare/main...${branch}" \
      --jq '{additions: ([.files[].additions] | add), deletions: ([.files[].deletions] | add), files: (.files | length), ahead: .ahead_by}' 2>/dev/null || echo '{"additions":0,"deletions":0,"files":0,"ahead":0}')
    branch_json=$(echo "$branch_json" | jq --arg name "$branch" --argjson stats "$bstats" \
      '. + [$stats + {name: $name}]')
  done

  if [ "$first" = true ]; then first=false; else echo ","; fi
  jq -nc --argjson issue "$issue_num" --arg title "$title" \
    --argjson attempts "$attempt_count" --arg risk "$risk" \
    --argjson branches "$branch_json" \
    '{issue: $issue, title: $title, attempts: $attempts, risk: $risk, branches: $branches}'
done
echo ""
echo "]"
