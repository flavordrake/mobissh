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

TIMESTAMP=$(date +%Y%m%dT%H%M%S)
TRACE_DIR=".traces/trace-${SLUG}-${TIMESTAMP}"

mkdir -p "${TRACE_DIR}/specs"
mkdir -p "${TRACE_DIR}/strategy"
mkdir -p "${TRACE_DIR}/logs"
mkdir -p "${TRACE_DIR}/telemetry"
mkdir -p "${TRACE_DIR}/artifacts"

GIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")

cat > "${TRACE_DIR}/TRACE.md" << EOF
---
id: trace-${SLUG}-${TIMESTAMP}
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
EOF

cat > "${TRACE_DIR}/strategy/initial_plan.md" << EOF
# Initial Strategy

## Objective
${SLUG}

## Approach
<!-- Document the initial approach before writing any code -->

## Assumptions
<!-- What are we assuming about the existing code? -->

## Expected Changes
<!-- Files to modify, test strategy, risk assessment -->
EOF

echo "+ TRACE initialized: ${TRACE_DIR}/"
echo "  Edit strategy/initial_plan.md before starting work"
