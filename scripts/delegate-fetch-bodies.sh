#!/usr/bin/env bash
# scripts/delegate-fetch-bodies.sh — Fetch full issue bodies for classified issues
#
# Reads delegate-classified.json and fetches full issue bodies for issues
# matching specified classifications. Outputs enriched JSON to stdout.
#
# Usage: bash scripts/delegate-fetch-bodies.sh [--data FILE] [--buckets BUCKET,...]
# Default input: /tmp/delegate-classified.json
# Default buckets: delegate,already-attempted,decompose
# Output: JSON array to stdout

set -euo pipefail

DATA="/tmp/delegate-classified.json"
BUCKETS="delegate,already-attempted,decompose"

while [[ $# -gt 0 ]]; do
  case $1 in
    --data) DATA="$2"; shift 2 ;;
    --buckets) BUCKETS="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ ! -f "$DATA" ]; then
  echo "Input not found: $DATA" >&2
  exit 1
fi

# Extract issue numbers for target buckets
NUMBERS=$(python3 -c "
import json, sys
buckets = set('$BUCKETS'.split(','))
with open('$DATA') as f:
    issues = json.load(f)
filtered = [i for i in issues if i.get('classification') in buckets]
print(f'Fetching {len(filtered)} issues in: {buckets}', file=sys.stderr)
for i in filtered:
    print(i['number'])
")

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Fetch each issue body to a temp file
for num in $NUMBERS; do
  echo "> #${num}" >&2
  gh issue view "$num" --json number,title,body,labels,comments \
    --jq '{
      number, title, body,
      labels: [.labels[].name],
      comment_count: (.comments | length),
      latest_comments: [.comments[-3:][] | {author: .author.login, body: .body[:500]}]
    }' > "${TMPDIR}/${num}.json" 2>/dev/null || echo "{\"number\":${num},\"error\":true}" > "${TMPDIR}/${num}.json"
done

# Merge into single JSON array, joined with classification data
python3 << MERGE
import json, os, sys

with open('$DATA') as f:
    classified = {i['number']: i for i in json.load(f)}

buckets = set('$BUCKETS'.split(','))
result = []

for fname in sorted(os.listdir('$TMPDIR')):
    if not fname.endswith('.json'):
        continue
    num = int(fname.replace('.json', ''))
    with open(os.path.join('$TMPDIR', fname)) as f:
        body_data = json.load(f)

    cls_data = classified.get(num, {})
    if cls_data.get('classification') not in buckets:
        continue

    merged = {**cls_data, **body_data}
    result.append(merged)

result.sort(key=lambda x: x['number'])
json.dump(result, sys.stdout, indent=2)
print(f'Wrote {len(result)} enriched issues', file=sys.stderr)
MERGE
