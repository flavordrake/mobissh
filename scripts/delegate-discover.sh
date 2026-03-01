#!/usr/bin/env bash
# scripts/delegate-discover.sh — Gather all open issues + bot branch history
#
# Fetches open issues, bot branches, and diff stats. Outputs a single JSON
# file with everything the delegate skill needs for classification.
#
# Usage: bash scripts/delegate-discover.sh [--out FILE]
# Default output: /tmp/delegate-data.json
#
# Each entry:
#   { number, title, labels, has_body, body, has_claude_comment,
#     bot_attempts, branches: [{name, diff_stat, files, additions, deletions}] }

set -euo pipefail

OUT="/tmp/delegate-data.json"
while [[ $# -gt 0 ]]; do
  case $1 in
    --out) OUT="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

log() { echo "> $*" >&2; }

REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')

# Step 1: Fetch all open issues (full body + comments)
log "Fetching open issues..."
gh issue list --state open --limit 100 \
  --json number,title,body,labels,comments \
  > /tmp/delegate-issues-raw.json
ISSUE_COUNT=$(jq length /tmp/delegate-issues-raw.json)
log "Found ${ISSUE_COUNT} open issues"

# Step 2: Get all bot branches
log "Fetching bot branches..."
BOT_BRANCHES=$(gh api "repos/${REPO}/branches" --paginate --jq '.[].name' \
  | grep '^claude/issue-' || true)

if [ -z "$BOT_BRANCHES" ]; then
  log "No bot branches found"
  echo "$BOT_BRANCHES" > /tmp/delegate-branches.txt
else
  echo "$BOT_BRANCHES" > /tmp/delegate-branches.txt
  log "Found $(echo "$BOT_BRANCHES" | wc -l) bot branches"
fi

# Step 3: For each issue with bot branches, get latest branch stats
log "Computing branch stats..."
declare -A ISSUE_BRANCH_DATA
for branch in $BOT_BRANCHES; do
  issue_num=$(echo "$branch" | grep -oP 'issue-\K\d+')
  # Get compare stats (additions, deletions, file count, filenames)
  stats=$(gh api "repos/${REPO}/compare/main...${branch}" \
    --jq '{
      additions: ([.files[].additions] | add // 0),
      deletions: ([.files[].deletions] | add // 0),
      files: (.files | length),
      filenames: [.files[].filename],
      ahead: .ahead_by
    }' 2>/dev/null || echo '{"additions":0,"deletions":0,"files":0,"filenames":[],"ahead":0}')

  entry=$(jq -nc --arg name "$branch" --argjson stats "$stats" '$stats + {name: $name}')

  if [ -n "${ISSUE_BRANCH_DATA[$issue_num]:-}" ]; then
    ISSUE_BRANCH_DATA[$issue_num]="${ISSUE_BRANCH_DATA[$issue_num]},$entry"
  else
    ISSUE_BRANCH_DATA[$issue_num]="$entry"
  fi
done

# Step 4: Assemble final JSON
log "Assembling output..."
python3 -c "
import json, sys

with open('/tmp/delegate-issues-raw.json') as f:
    issues = json.load(f)

# Parse branch data from env-provided JSON lines
branch_data = {}
$(for issue_num in "${!ISSUE_BRANCH_DATA[@]}"; do
    echo "branch_data[$issue_num] = json.loads('[${ISSUE_BRANCH_DATA[$issue_num]}]')"
done)

result = []
for issue in issues:
    num = issue['number']
    body = issue.get('body') or ''
    comments = issue.get('comments', [])
    branches = branch_data.get(num, [])

    entry = {
        'number': num,
        'title': issue['title'],
        'labels': [l['name'] for l in issue.get('labels', [])],
        'has_body': bool(body.strip()),
        'body': body,
        'has_claude_comment': any('@claude' in (c.get('body', '') or '') for c in comments),
        'comment_count': len(comments),
        'bot_attempts': len(branches),
        'branches': sorted(branches, key=lambda b: b['name']),
    }
    result.append(entry)

result.sort(key=lambda x: x['number'])

with open('$OUT', 'w') as f:
    json.dump(result, f, indent=2)

# Print summary to stderr
attempted = [r for r in result if r['bot_attempts'] > 0]
print(f'Wrote {len(result)} issues to $OUT', file=sys.stderr)
print(f'Issues with bot attempts: {len(attempted)}', file=sys.stderr)
for r in attempted:
    latest = r['branches'][-1] if r['branches'] else {}
    print(f'  #{r[\"number\"]} ({r[\"bot_attempts\"]} attempts) latest: +{latest.get(\"additions\",0)}/-{latest.get(\"deletions\",0)} {latest.get(\"files\",0)} files', file=sys.stderr)
"

log "Done: ${OUT}"
