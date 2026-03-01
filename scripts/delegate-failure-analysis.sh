#!/usr/bin/env bash
# scripts/delegate-failure-analysis.sh — Analyze bot branch failures for an issue
#
# For a given issue number, fetches the latest bot branch, diffs it against main,
# runs classification heuristics, and outputs structured JSON.
#
# Usage: bash scripts/delegate-failure-analysis.sh <issue-number> [--data FILE]
#
# If --data is provided, reads from delegate-discover.sh output instead of
# re-fetching. Otherwise fetches live from GitHub.
#
# Output (JSON to stdout):
#   { issue, attempts, latest_branch, failure_type, signals, diff_stat,
#     files_changed, filenames, additions, deletions, diff_sample }
#
# failure_type: over-engineered | scope-creep | stale-base | small-testable | unknown

set -euo pipefail

ISSUE_NUM="${1:-}"
DATA_FILE=""
shift || true

while [[ $# -gt 0 ]]; do
  case $1 in
    --data) DATA_FILE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [ -z "$ISSUE_NUM" ]; then
  echo "Usage: bash scripts/delegate-failure-analysis.sh <issue-number> [--data FILE]" >&2
  exit 1
fi

log() { echo "> $*" >&2; }

# Get branch info
if [ -n "$DATA_FILE" ] && [ -f "$DATA_FILE" ]; then
  ISSUE_DATA=$(jq ".[] | select(.number == $ISSUE_NUM)" "$DATA_FILE")
  ATTEMPTS=$(echo "$ISSUE_DATA" | jq '.bot_attempts // 0')

  # Handle both data formats: branches array (delegate-discover.sh) or flat fields (ad-hoc)
  HAS_BRANCHES_ARRAY=$(echo "$ISSUE_DATA" | jq 'has("branches") and (.branches | length > 0)')
  if [ "$HAS_BRANCHES_ARRAY" = "true" ]; then
    LATEST_BRANCH=$(echo "$ISSUE_DATA" | jq -r '.branches[-1].name // empty')
    ADDITIONS=$(echo "$ISSUE_DATA" | jq '.branches[-1].additions // 0')
    DELETIONS=$(echo "$ISSUE_DATA" | jq '.branches[-1].deletions // 0')
    FILE_COUNT=$(echo "$ISSUE_DATA" | jq '.branches[-1].files // 0')
    FILENAMES=$(echo "$ISSUE_DATA" | jq '.branches[-1].filenames // []')
    AHEAD=$(echo "$ISSUE_DATA" | jq '.branches[-1].ahead // 0')
  else
    # Flat format: latest_branch, diff_stat as strings
    LATEST_BRANCH=$(echo "$ISSUE_DATA" | jq -r '.latest_branch // empty')
    ADDITIONS=0; DELETIONS=0; FILE_COUNT=0; FILENAMES="[]"; AHEAD=1
  fi
else
  REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
  BRANCHES=$(gh api "repos/${REPO}/branches" --paginate --jq '.[].name' \
    | grep "^claude/issue-${ISSUE_NUM}-" || true)

  if [ -z "$BRANCHES" ]; then
    jq -nc --argjson issue "$ISSUE_NUM" '{issue: $issue, attempts: 0, failure_type: "none", signals: ["no bot branches found"]}'
    exit 0
  fi

  ATTEMPTS=$(echo "$BRANCHES" | wc -l)
  LATEST_BRANCH=$(echo "$BRANCHES" | sort | tail -1)

  stats=$(gh api "repos/${REPO}/compare/main...${LATEST_BRANCH}" \
    --jq '{additions: ([.files[].additions] | add // 0), deletions: ([.files[].deletions] | add // 0), files: (.files | length), filenames: [.files[].filename], ahead: .ahead_by}' \
    2>/dev/null || echo '{"additions":0,"deletions":0,"files":0,"filenames":[],"ahead":0}')

  ADDITIONS=$(echo "$stats" | jq '.additions')
  DELETIONS=$(echo "$stats" | jq '.deletions')
  FILE_COUNT=$(echo "$stats" | jq '.files')
  FILENAMES=$(echo "$stats" | jq '.filenames')
  AHEAD=$(echo "$stats" | jq '.ahead')
fi

if [ -z "$LATEST_BRANCH" ] || [ "$LATEST_BRANCH" = "null" ]; then
  jq -nc --argjson issue "$ISSUE_NUM" '{issue: $issue, attempts: 0, failure_type: "none", signals: ["no branches"]}'
  exit 0
fi

TOTAL_LINES=$((ADDITIONS + DELETIONS))

# Fetch the actual diff for content analysis
log "Fetching diff for ${LATEST_BRANCH}..."
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')

# Check if the branch still exists on the remote
BRANCH_EXISTS=$(gh api "repos/${REPO}/branches/${LATEST_BRANCH}" --jq '.name' 2>/dev/null || echo "")
if [ -z "$BRANCH_EXISTS" ]; then
  # Branch was deleted (cleaned up by integrate). Report what we know from data file.
  jq -nc \
    --argjson issue "$ISSUE_NUM" \
    --argjson attempts "${ATTEMPTS:-0}" \
    --arg latest_branch "$LATEST_BRANCH" \
    '{
      issue: $issue,
      attempts: $attempts,
      latest_branch: $latest_branch,
      failure_type: "branches-deleted",
      signals: ["all bot branches deleted (prior cleanup)", "re-delegate from scratch"],
      additions: 0, deletions: 0, files_changed: 0, filenames: [], diff_sample: ""
    }'
  exit 0
fi

DIFF=$(gh api "repos/${REPO}/compare/main...${LATEST_BRANCH}" \
  --jq '[.files[] | "--- \(.filename)\n+++ \(.patch // "(binary)")"] | join("\n\n")' 2>/dev/null || echo "")

# Re-fetch stats from live API if data file gave zeros (stale data)
if [ "$TOTAL_LINES" -eq 0 ] && [ "$AHEAD" -le 0 ]; then
  log "Data file stats stale, fetching live..."
  live_stats=$(gh api "repos/${REPO}/compare/main...${LATEST_BRANCH}" \
    --jq '{additions: ([.files[].additions] | add // 0), deletions: ([.files[].deletions] | add // 0), files: (.files | length), filenames: [.files[].filename], ahead: .ahead_by}' \
    2>/dev/null || echo '{"additions":0,"deletions":0,"files":0,"filenames":[],"ahead":0}')
  ADDITIONS=$(echo "$live_stats" | jq '.additions')
  DELETIONS=$(echo "$live_stats" | jq '.deletions')
  FILE_COUNT=$(echo "$live_stats" | jq '.files')
  FILENAMES=$(echo "$live_stats" | jq '.filenames')
  AHEAD=$(echo "$live_stats" | jq '.ahead')
  TOTAL_LINES=$((ADDITIONS + DELETIONS))
fi

# Classify failure type and collect signals
SIGNALS="[]"
FAILURE_TYPE="unknown"

add_signal() {
  SIGNALS=$(echo "$SIGNALS" | jq --arg s "$1" '. + [$s]')
}

# Check: stale base (0 commits ahead = already merged or empty)
if [ "$AHEAD" -eq 0 ]; then
  FAILURE_TYPE="stale-base"
  add_signal "0 commits ahead of main (already merged or empty)"
fi

# Check: over-engineered (too many lines or files for the issue)
if [ "$TOTAL_LINES" -gt 200 ]; then
  add_signal "total diff ${TOTAL_LINES} lines (budget: 150)"
  if [ "$FAILURE_TYPE" = "unknown" ]; then FAILURE_TYPE="over-engineered"; fi
fi

if [ "$FILE_COUNT" -gt 5 ]; then
  add_signal "${FILE_COUNT} files changed (threshold: 3-5)"
  if [ "$FAILURE_TYPE" = "unknown" ]; then FAILURE_TYPE="over-engineered"; fi
fi

# Check: scope creep (touches server, tests, or unrelated modules)
HAS_SERVER=$(echo "$FILENAMES" | jq '[.[] | select(startswith("server/"))] | length')
HAS_TESTS=$(echo "$FILENAMES" | jq '[.[] | select(startswith("tests/"))] | length')
HAS_CONFIG=$(echo "$FILENAMES" | jq '[.[] | select(. == "tsconfig.json" or . == "package.json" or . == ".eslintrc.json")] | length')

if [ "$HAS_SERVER" -gt 0 ]; then
  add_signal "touches server/ (${HAS_SERVER} files)"
fi
if [ "$HAS_CONFIG" -gt 0 ]; then
  add_signal "touches config files"
fi
if [ "$HAS_TESTS" -gt 0 ]; then
  add_signal "modifies test files (${HAS_TESTS} files)"
fi

# Check: small and potentially testable
if [ "$TOTAL_LINES" -le 100 ] && [ "$FILE_COUNT" -le 3 ] && [ "$AHEAD" -gt 0 ]; then
  FAILURE_TYPE="small-testable"
  add_signal "small diff (${TOTAL_LINES} lines, ${FILE_COUNT} files) — may be re-delegatable"
fi

# Trim diff sample to first 2000 chars for context
DIFF_SAMPLE=$(echo "$DIFF" | head -c 2000)

# Output
jq -nc \
  --argjson issue "$ISSUE_NUM" \
  --argjson attempts "$ATTEMPTS" \
  --arg latest_branch "$LATEST_BRANCH" \
  --arg failure_type "$FAILURE_TYPE" \
  --argjson signals "$SIGNALS" \
  --argjson additions "$ADDITIONS" \
  --argjson deletions "$DELETIONS" \
  --argjson files "$FILE_COUNT" \
  --argjson filenames "$FILENAMES" \
  --arg diff_sample "$DIFF_SAMPLE" \
  '{
    issue: $issue,
    attempts: $attempts,
    latest_branch: $latest_branch,
    failure_type: $failure_type,
    signals: $signals,
    additions: $additions,
    deletions: $deletions,
    files_changed: $files,
    filenames: $filenames,
    diff_sample: $diff_sample
  }'
