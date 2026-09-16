#!/usr/bin/env bash
# scripts/native-coverage.sh — Flutter unit suite instrumented for line coverage (#1152)
#
# Assessment tool, not a gate: native-fast-gate.sh keeps running the suite
# uninstrumented because `--coverage` is markedly slower. Same test selection
# as gate 2 (`--exclude-tags integration`); Flutter writes native/coverage/
# lcov.info itself (no `coverage` pub dependency), then lcov-summary.sh prints
# the rollup for native/lib including the never-loaded file list. The disk
# preflight (lib/disk-guard.sh) runs inside flutter-cmd.sh like every build.
#
# Usage: scripts/native-coverage.sh [--markdown]
#   --markdown   print the report form instead of TSV (coverage-report.sh).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_LOGDIR"
LOGFILE="${MOBISSH_LOGDIR}/native-coverage.log"
NATIVE_DIR="${REPO_ROOT}/native"
LCOV="native/coverage/lcov.info"

cd "$REPO_ROOT"
rm -f "$LCOV"
echo "> $(date -u +%H:%M:%SZ) flutter test --coverage (log: ${LOGFILE})" >&2
if ! "${REPO_ROOT}/scripts/flutter-cmd.sh" --in "$NATIVE_DIR" test --coverage \
    --exclude-tags integration >"$LOGFILE" 2>&1; then
  echo "! flutter test --coverage FAILED, see ${LOGFILE}" >&2
  exit 1
fi
[[ -f "$LCOV" ]] || { echo "! no lcov written at ${LCOV}" >&2; exit 1; }
echo "> $(date -u +%H:%M:%SZ) lcov: ${LCOV} ($(wc -l <"$LCOV") lines)" >&2
exec scripts/lcov-summary.sh "$LCOV" native/lib "$@"
