#!/usr/bin/env bash
# scripts/test-unit.sh — Vitest unit tests
#
# Runs vitest against src/**/*.test.ts (per vitest.config.mts).
# No browser, no Playwright, no Appium. Pure Node.js tests.
# Exit 0 on success, 1 on test failures.

set -euo pipefail
cd "$(dirname "$0")/.."

LOGFILE=/tmp/test-unit.log
exec > >(tee "$LOGFILE") 2>&1

npx vitest run
