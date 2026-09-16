#!/usr/bin/env bash
# scripts/ts-coverage.sh — vitest unit tests instrumented with @vitest/coverage-v8 (#1152)
#
# Assessment tool, not a gate: the fast gate keeps running scripts/test-unit.sh
# uninstrumented. This writes coverage/lcov.info (gitignored) via the coverage
# block in vitest.config.mts and prints the lcov-summary.sh rollup for src/.
#
# Usage: scripts/ts-coverage.sh [--markdown]
#   --markdown   print the report form instead of TSV (coverage-report.sh).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_LOGDIR"
LOGFILE="${MOBISSH_LOGDIR}/ts-coverage.log"
LCOV="coverage/lcov.info"

cd "$REPO_ROOT"
echo "> $(date -u +%H:%M:%SZ) vitest run --coverage (log: ${LOGFILE})" >&2
if ! npx vitest run --coverage >"$LOGFILE" 2>&1; then
  echo "! vitest --coverage FAILED, see ${LOGFILE}" >&2
  exit 1
fi
[[ -f "$LCOV" ]] || { echo "! no lcov written at ${LCOV}" >&2; exit 1; }
echo "> $(date -u +%H:%M:%SZ) lcov: ${LCOV} ($(wc -l <"$LCOV") lines)" >&2
exec scripts/lcov-summary.sh "$LCOV" src --ext ts "$@"
