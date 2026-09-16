#!/usr/bin/env bash
# scripts/coverage-report.sh — one-shot coverage snapshot, native + TS (#1152)
#
# NOT wired into any gate, on purpose: instrumented runs are slower and
# coverage here is an assessment input (what to delete vs. cover), not a merge
# criterion. No thresholds. Runs scripts/native-coverage.sh and
# scripts/ts-coverage.sh once each and archives:
#
#   test-history/coverage/<UTC stamp>/native.md     committed report
#   test-history/coverage/<UTC stamp>/ts.md         committed report
#   test-history/coverage/<UTC stamp>/native.lcov   local only (gitignored)
#   test-history/coverage/<UTC stamp>/ts.lcov       local only (gitignored)
#
# then prints the per-directory rollup and total for both trees. The raw lcov
# stays out of git (native.lcov is multi-MB per run); the .md is the artefact.
#
# Usage: scripts/coverage-report.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="test-history/coverage/${STAMP}"

cd "$REPO_ROOT"
mkdir -p "$OUT"
echo "> coverage report ${STAMP} -> ${OUT}"
scripts/native-coverage.sh --markdown >"${OUT}/native.md"
cp native/coverage/lcov.info "${OUT}/native.lcov"
scripts/ts-coverage.sh --markdown >"${OUT}/ts.md"
cp coverage/lcov.info "${OUT}/ts.lcov"

echo "> native (native/lib)"
scripts/lcov-summary.sh "${OUT}/native.lcov" native/lib | grep -E '^(dir|total|never-loaded-count)'
echo "> ts (src)"
scripts/lcov-summary.sh "${OUT}/ts.lcov" src --ext ts | grep -E '^(dir|total|never-loaded-count)'
echo "+ reports: ${OUT}/native.md ${OUT}/ts.md"
