#!/usr/bin/env bash
# scripts/cycle-filter.sh — Discover, classify, and filter issues by theme for /cycle
#
# Usage:
#   scripts/cycle-filter.sh                     # auto-detect theme from git log
#   scripts/cycle-filter.sh "ime preview"       # explicit theme keywords
#   scripts/cycle-filter.sh --dry-run            # just print, no cluster analysis
#
# Output: writes triage table to stdout, cluster JSON to $MOBISSH_TMPDIR/cycle-clusters.json
# Requires: delegate-discover.sh, delegate-classify.sh

set -euo pipefail

MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"

THEME=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY_RUN=true; shift ;;
    *) THEME="$1"; shift ;;
  esac
done

# Phase 1: Discover (if data is stale or missing)
DATA="${MOBISSH_TMPDIR}/delegate-data.json"
CLASSIFIED="${MOBISSH_TMPDIR}/delegate-classified.json"
CYCLE_OUT="${MOBISSH_TMPDIR}/cycle-filtered.json"
CLUSTER_OUT="${MOBISSH_TMPDIR}/cycle-clusters.json"

# Re-discover if data is older than 10 minutes or missing
REFRESH=false
if [ ! -f "$DATA" ]; then
  REFRESH=true
else
  AGE=$(( $(date +%s) - $(stat -c %Y "$DATA") ))
  if [ "$AGE" -gt 600 ]; then
    REFRESH=true
  fi
fi

if [ "$REFRESH" = true ]; then
  echo "> Discovering open issues..." >&2
  scripts/delegate-discover.sh >&2
fi

# Phase 2: Classify (if classified data is stale)
if [ ! -f "$CLASSIFIED" ] || [ "$DATA" -nt "$CLASSIFIED" ]; then
  echo "> Classifying issues..." >&2
  scripts/delegate-classify.sh >&2
fi

# Phase 3: Auto-detect theme from git log if not provided
if [ -z "$THEME" ]; then
  echo "> Auto-detecting theme from recent commits..." >&2
  THEME=$(git log --oneline -20 | python3 -c "
import sys, re, collections
words = collections.Counter()
stop = {'fix','feat','chore','bug','merge','pull','request','from','the','and','for','with','add','update','in','on','to','a','of','no','not','all'}
for line in sys.stdin:
    tokens = re.findall(r'[a-z]+', line.lower())
    for t in tokens:
        if t not in stop and len(t) > 2:
            words[t] += 1
# Pick top 5 most frequent meaningful words
top = [w for w, _ in words.most_common(10) if w not in stop][:5]
print(' '.join(top))
")
  echo "> Detected theme: $THEME" >&2
fi

# Phase 4: Filter and cluster
python3 - "$CLASSIFIED" "$CYCLE_OUT" "$CLUSTER_OUT" "$THEME" << 'FILTER'
import json, re, sys

classified_path = sys.argv[1]
filtered_path = sys.argv[2]
cluster_path = sys.argv[3]
theme_words = sys.argv[4].lower().split()

with open(classified_path) as f:
    issues = json.load(f)

# Skip icebox, close, already-closed
skip_classes = {'icebox', 'close'}

# Score each issue by theme relevance
scored = []
for issue in issues:
    if issue['classification'] in skip_classes:
        continue
    title = issue['title'].lower()
    body = issue.get('body', '').lower()
    labels = [l.lower() for l in issue.get('labels', [])]
    text = title + ' ' + body + ' ' + ' '.join(labels)

    # Count theme keyword matches
    hits = sum(1 for kw in theme_words if kw in text)
    if hits > 0:
        issue['theme_score'] = hits
        scored.append(issue)

# Sort by theme score desc, then by issue number
scored.sort(key=lambda x: (-x['theme_score'], x['number']))

# Write filtered issues
with open(filtered_path, 'w') as f:
    json.dump(scored, f, indent=2)

# Cluster by shared concern (simple keyword-based)
clusters = {}
cluster_defs = {
    'voice': ['voice', 'speech', 'dictation', 'recognition'],
    'preview': ['preview', 'previewing', 'preview mode', 'preview box', 'auto-clear', 'timeout'],
    'compose': ['compose', 'composing', 'composition', 'commit', 'aggressiveness'],
    'keybar': ['key bar', 'keybar', 'modifier', 'ctrl', 'alt'],
    'swipe': ['swipe', 'correction', 'replacement', 'diff'],
    'test-infra': ['test suite', 'emulator test', 'recording', 'test infra'],
    'styling': ['styling', 'css', 'color', 'accent', 'border', 'grow', 'resize'],
}

for issue in scored:
    text = (issue['title'] + ' ' + issue.get('body', '')).lower()
    matched_clusters = []
    for cname, keywords in cluster_defs.items():
        if any(kw in text for kw in keywords):
            matched_clusters.append(cname)
    if not matched_clusters:
        matched_clusters = ['unclustered']
    for c in matched_clusters:
        clusters.setdefault(c, [])
        clusters[c].append(issue['number'])

with open(cluster_path, 'w') as f:
    json.dump(clusters, f, indent=2)

# Print triage table
print(f"\nTheme: \"{' '.join(theme_words)}\"")
print(f"Found: {len(scored)} issues matching theme\n")
print(f"| {'#':>4} | {'Title':<65} | {'Class':<18} | {'Score':>5} |")
print(f"|{'-'*6}|{'-'*67}|{'-'*20}|{'-'*7}|")
for i in scored:
    title = i['title'][:65]
    print(f"| {i['number']:4d} | {title:<65} | {i['classification']:<18} | {i['theme_score']:5d} |")

# Print clusters
print(f"\n## Clusters\n")
for cname, nums in sorted(clusters.items(), key=lambda x: -len(x[1])):
    issue_refs = ', '.join(f"#{n}" for n in nums)
    print(f"**{cname}** ({len(nums)}): {issue_refs}")

# Print actionable summary
delegate = [i for i in scored if i['classification'] == 'delegate']
decompose = [i for i in scored if i['classification'] == 'decompose']
human = [i for i in scored if i['classification'] == 'human-only']
attempted = [i for i in scored if i['classification'] == 'already-attempted']

print(f"\n## Summary")
print(f"- Ready to develop: {len(delegate)}")
print(f"- Need decomposition: {len(decompose)}")
print(f"- Already attempted: {len(attempted)}")
print(f"- Human-only: {len(human)}")
FILTER

echo "" >&2
echo "> Filtered: $CYCLE_OUT" >&2
echo "> Clusters: $CLUSTER_OUT" >&2
