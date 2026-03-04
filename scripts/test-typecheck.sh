#!/usr/bin/env bash
# scripts/test-typecheck.sh — TypeScript type checking
#
# Runs tsc --noEmit against the project. No compilation output.
# Exit 0 on success, 1 on type errors.

set -euo pipefail
cd "$(dirname "$0")/.."

LOGFILE=/tmp/test-typecheck.log
exec > >(tee "$LOGFILE") 2>&1

npx tsc --noEmit
