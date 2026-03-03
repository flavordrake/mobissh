#!/usr/bin/env bash
# scripts/parse-appium-results.sh — Parse Appium test results from JSON reporter
#
# Usage:
#   scripts/parse-appium-results.sh                          # default path
#   scripts/parse-appium-results.sh /path/to/results.json    # specific file
#
# Reads the Playwright JSON reporter output and prints a summary.

set -euo pipefail

JSON="${1:-test-results-appium/results.json}"

if [[ ! -f "$JSON" ]]; then
  echo "Results file not found: $JSON" >&2
  echo "Run tests first, or pass the path to results.json" >&2
  exit 1
fi

python3 -c "
import json, sys

with open('$JSON') as f:
    data = json.load(f)

passed = failed = skipped = retried = 0
specs = {}  # spec_file -> [(status, title, duration_ms, was_retried)]

for suite in data.get('suites', []):
    for spec in suite.get('suites', []):
        spec_file = suite.get('title', 'unknown')
        if spec_file not in specs:
            specs[spec_file] = []
        for test in spec.get('specs', []):
            title = test.get('title', '?')
            results = test.get('tests', []) or []
            # Each 'test' entry has results array; last result is final verdict
            final = None
            was_retried = len(results) > 1
            for r in results:
                rs = r.get('results', [])
                for attempt in rs:
                    final = attempt
            if not final:
                continue
            status = final.get('status', 'unknown')
            duration = final.get('duration', 0)
            if status == 'passed':
                passed += 1
            elif status == 'failed' or status == 'timedOut':
                failed += 1
            elif status == 'skipped':
                skipped += 1
            if was_retried:
                retried += 1
            specs[spec_file].append((status, title, duration, was_retried))

total = passed + failed + skipped
duration_s = data.get('stats', {}).get('duration', 0) / 1000
duration_str = f'{duration_s:.0f}s' if duration_s < 120 else f'{duration_s/60:.1f}m'

print(f'{passed} passed, {failed} failed ({total} total, {retried} retried) in {duration_str}')
print()

for spec_file in sorted(specs.keys()):
    tests = specs[spec_file]
    p = sum(1 for s,_,_,_ in tests if s == 'passed')
    f = sum(1 for s,_,_,_ in tests if s in ('failed', 'timedOut'))
    label = 'FAIL' if f > 0 else 'OK  '
    counts = f'{p} pass' + (f', {f} fail' if f else '')
    print(f'{label} {spec_file} ({counts})')
    for status, title, dur_ms, was_retried in tests:
        tag = 'PASS' if status == 'passed' else 'FAIL'
        dur = f'{dur_ms/1000:.1f}s'
        retry = ' [retried]' if was_retried else ''
        print(f'  {tag}  {title} ({dur}){retry}')

sys.exit(1 if failed > 0 else 0)
"
