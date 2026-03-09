#!/usr/bin/env bash
# scripts/test-fast-gate.sh — Run the fast gate: typecheck + lint + unit tests
#
# Usage: scripts/test-fast-gate.sh
#
# Exit codes:
#   0 — all gates passed
#   1 — one or more gates failed

set -euo pipefail

cd "$(dirname "$0")/.."

PASS=true

echo "> Gate 1/3: TypeScript typecheck..."
if scripts/test-typecheck.sh; then
  echo "+ tsc: pass"
else
  echo "! tsc: FAIL" >&2
  PASS=false
fi

echo "> Gate 2/3: ESLint..."
if scripts/test-lint.sh; then
  echo "+ eslint: pass"
else
  echo "! eslint: FAIL" >&2
  PASS=false
fi

echo "> Gate 3/3: Unit tests (vitest)..."
if scripts/test-unit.sh; then
  echo "+ vitest: pass"
else
  echo "! vitest: FAIL" >&2
  PASS=false
fi

if [ "$PASS" = true ]; then
  echo "+ FAST GATE PASSED"
else
  echo "! FAST GATE FAILED" >&2
  exit 1
fi
