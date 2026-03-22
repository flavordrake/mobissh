#!/usr/bin/env bash
# scripts/trace-init.sh — Initialize a TRACE directory for agent trajectory capture
#
# Usage:
#   scripts/trace-init.sh "objective-slug"
#   scripts/trace-init.sh "sftp-upload-throughput"
#
# Creates: .traces/trace-{slug}-{timestamp}/

set -euo pipefail
cd "$(dirname "$0")/.."

SLUG="${1:-}"
if [ -z "$SLUG" ]; then
  echo "Usage: scripts/trace-init.sh <objective-slug>" >&2
  exit 1
fi

# Short timestamp suffix for uniqueness — slug provides the context
TRACE_DIR=".traces/trace-${SLUG}-$(date +%H%M%S)"

mkdir -p "${TRACE_DIR}/specs"
mkdir -p "${TRACE_DIR}/strategy"
mkdir -p "${TRACE_DIR}/logs"
mkdir -p "${TRACE_DIR}/telemetry"
mkdir -p "${TRACE_DIR}/artifacts"

GIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")

cat > "${TRACE_DIR}/TRACE.md" << EOF
---
id: trace-${SLUG}
objective: "${SLUG}"
status: in-progress
skills-used: []
branch: ${BRANCH}
git-hash: ${GIT_HASH}
created: $(date -Iseconds)
resources:
  tokens: 0
  compute_footprint:
    cpu_time: "00m:00s"
    wall_time: "00m:00s"
metrics:
  target: ""
  achieved: ""
---

# TRACE: ${SLUG}

## The "Why"
<!-- Post-mortem: why did the final strategy succeed or fail? -->

## The "Ambiguity Gap"
<!-- How were specs clarified during execution? What was assumed vs stated? -->

## The "Knowledge Seed"
<!-- One-sentence heuristic for future agents -->

## Performance Delta
<!-- One-line: before/after impact. Reference telemetry/perf-*.txt -->

## Security Summary
<!-- One-line: static analysis findings on changed files. Reference logs/security-findings.md -->

## Outcome Classification
<!-- success | success-with-caveats | partial | failure-informative | failure -->
EOF

cat > "${TRACE_DIR}/strategy/initial_plan.md" << EOF
# Initial Strategy

Issue: ${SLUG}
Approach: as described in issue body

## Assumptions that might be wrong
<!-- List only non-obvious assumptions — don't restate the issue -->

## Notes
<!-- Anything not in the issue that affects approach -->
EOF

echo "+ TRACE initialized: ${TRACE_DIR}/"
echo "  Edit strategy/initial_plan.md before starting work"
