#!/usr/bin/env bash
# scripts/delegate-classify.sh — Apply deterministic classification rules
#
# Reads delegate-discover.sh output and classifies each issue into buckets.
# Non-deterministic judgment (research, decomposition design) is left to the agent.
#
# Usage: scripts/delegate-classify.sh [--data FILE] [--out FILE]
# Default input: $MOBISSH_TMPDIR/delegate-data.json
# Default output: $MOBISSH_TMPDIR/delegate-classified.json
# Summary printed to stderr
#
# Buckets:
#   delegate          — clear scope, bot-ready
#   already-attempted — has bot branches, needs failure analysis
#   decompose         — too large or vague for one pass
#   human-only        — device testing, research, UX judgment
#   blocked           — depends on unresolved issue
#   icebox            — labeled icebox, skip entirely
#   close             — superseded or stale
#
# Test-fixup branches (only touch tests/) are part of the two-pass workflow
# and don't count as failed feature attempts for know-when-to-quit rules.

set -euo pipefail

MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"
DATA="${MOBISSH_TMPDIR}/delegate-data.json"
OUT="${MOBISSH_TMPDIR}/delegate-classified.json"
while [[ $# -gt 0 ]]; do
  case $1 in
    --data) DATA="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ ! -f "$DATA" ]; then
  echo "Input not found: $DATA" >&2
  exit 1
fi

python3 - "$DATA" "$OUT" << 'CLASSIFY'
import json, re, sys

HUMAN_KEYWORDS = re.compile(
    r'\b(research|evaluate|investigate|explore|user testing|UX judgment)\b',
    re.IGNORECASE
)
# Only match device keywords in TITLE (not body — many issues mention platforms in context)
DEVICE_TITLE_KEYWORDS = re.compile(
    r'\b(ios|safari|iphone|ipad)\b',
    re.IGNORECASE
)
TOUCH_TITLE_KEYWORDS = re.compile(
    r'\b(touch|gesture|swipe|pinch|biometric|fingerprint)\b',
    re.IGNORECASE
)
BLOCKED_PATTERN = re.compile(
    r'(depends on|blocked by|after #|prerequisite.*#)\s*(\d+)',
    re.IGNORECASE
)
ACTIONABLE_KEYWORDS = re.compile(
    r'\b(change|fix|add|remove|update|set|replace|use|switch|move|collapse|suppress|warn|hide|show)\b',
    re.IGNORECASE
)
LARGE_FEATURE_KEYWORDS = re.compile(
    r'\b(multiplexer|multi-session|file browser|sftp|scp|editor)\b',
    re.IGNORECASE
)

data_path = sys.argv[1] if len(sys.argv) > 1 else '/tmp/mobissh/delegate-data.json'
out_path = sys.argv[2] if len(sys.argv) > 2 else '/tmp/mobissh/delegate-classified.json'
with open(data_path) as f:
    issues = json.load(f)

open_numbers = {i['number'] for i in issues}

for issue in issues:
    num = issue['number']
    title = issue['title']
    body = issue.get('body', '') or ''
    text = f"{title} {body}"
    labels = issue.get('labels', [])
    attempts = issue.get('bot_attempts', 0)
    branches = issue.get('branches', [])
    latest = branches[-1] if branches else {}
    additions = latest.get('additions', 0)
    deletions = latest.get('deletions', 0)
    files = latest.get('files', 0)
    total_lines = additions + deletions

    signals = []
    bucket = None

    # Rule 0: Icebox label → skip entirely
    labels = [l.get('name', '') if isinstance(l, dict) else str(l) for l in issue.get('labels', [])]
    if 'icebox' in labels:
        bucket = 'icebox'
        signals.append('labeled icebox')

    # Rule 1: Has bot branches → already-attempted (needs failure analysis)
    # Test-fixup branches (only touch tests/) are a normal part of the two-pass
    # workflow and don't count as failed feature attempts.
    if attempts > 0:
        latest_files = latest.get('filenames', [])
        latest_is_test_fixup = bool(latest_files) and all(
            f.startswith('tests/') for f in latest_files
        )
        feature_attempts = sum(
            1 for b in branches
            if not (b.get('filenames') and all(
                f.startswith('tests/') for f in b['filenames']
            ))
        )
        if latest_is_test_fixup:
            signals.append(f'{attempts} branch(es), latest is test-fixup pass')
            if feature_attempts > 0:
                bucket = 'already-attempted'
                signals.append(f'{feature_attempts} feature attempt(s) before test-fixup')
            # else: all branches are test-fixup, don't block as already-attempted
        else:
            bucket = 'already-attempted'
            signals.append(f'{attempts} bot attempt(s)')
        if total_lines > 200:
            signals.append(f'latest diff {total_lines} lines (over budget)')
        if files > 5:
            signals.append(f'latest touched {files} files')
        if feature_attempts >= 3:
            signals.append('3+ feature attempts: know-when-to-quit threshold')

    # Rule 2: No body → needs human scoping
    if not issue.get('has_body'):
        if bucket is None:
            bucket = 'human-only'
        signals.append('no issue body')

    # Rule 3: Blocked by another open issue
    blocked_matches = BLOCKED_PATTERN.findall(text)
    for _, dep_num in blocked_matches:
        if int(dep_num) in open_numbers:
            if bucket is None:
                bucket = 'blocked'
            signals.append(f'depends on open #{dep_num}')

    # Rule 4: Human-only keywords (research, evaluate, investigate)
    if HUMAN_KEYWORDS.search(title):
        if bucket is None:
            bucket = 'human-only'
        signals.append('human-only keywords in title')

    # Rule 5: Device/platform keywords in title
    if DEVICE_TITLE_KEYWORDS.search(title):
        if bucket is None:
            bucket = 'human-only'
        signals.append('device/platform keywords in title')

    # Rule 6: Touch/gesture keywords in title (needs device testing)
    if TOUCH_TITLE_KEYWORDS.search(title):
        if bucket is None:
            bucket = 'human-only'
        signals.append('touch/gesture keywords in title')

    # Rule 7: iOS label
    if 'ios' in labels:
        if bucket is None:
            bucket = 'human-only'
        signals.append('ios label')

    # Rule 8: Large feature scope (title-based)
    if LARGE_FEATURE_KEYWORDS.search(title) and bucket is None:
        bucket = 'decompose'
        signals.append('large feature keywords in title')

    # Rule 9: Fallback classification based on body analysis
    if bucket is None:
        body_lines = len(body.strip().split('\n')) if body.strip() else 0
        has_structure = bool(re.search(r'(##|acceptance|criteria|expected|should|must)', body, re.IGNORECASE))
        is_actionable = bool(ACTIONABLE_KEYWORDS.search(title))

        if body_lines > 40 and not has_structure:
            bucket = 'decompose'
            signals.append(f'long body ({body_lines} lines) without structure')
        elif is_actionable:
            bucket = 'delegate'
            signals.append('actionable title, no blocking signals')
        elif has_structure:
            bucket = 'delegate'
            signals.append('structured body, no blocking signals')
        elif body_lines <= 3:
            bucket = 'human-only'
            signals.append('minimal body, needs scoping')
        else:
            bucket = 'delegate'
            signals.append('no blocking signals detected')

    issue['classification'] = bucket
    issue['classification_signals'] = signals

# Group and print summary
groups = {}
for issue in issues:
    bucket = issue['classification']
    groups.setdefault(bucket, []).append(issue)

# Print summary to stderr
for bucket in ['delegate', 'already-attempted', 'decompose', 'human-only', 'blocked', 'icebox', 'close']:
    items = groups.get(bucket, [])
    if items:
        print(f'\n{bucket.upper()} ({len(items)}):', file=sys.stderr)
        for i in items:
            sigs = '; '.join(i['classification_signals'])
            print(f'  #{i["number"]:>3} {i["title"][:60]:60} [{sigs}]', file=sys.stderr)

# Write full classified JSON to output file
with open(out_path, 'w') as f:
    json.dump(issues, f, indent=2)
print(f'Wrote {len(issues)} issues to {out_path}', file=sys.stderr)
CLASSIFY
