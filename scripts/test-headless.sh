#!/usr/bin/env bash
# scripts/test-headless.sh — Headless Playwright browser tests
#
# Runs Playwright with the default config (playwright.config.js), which
# emulates Pixel 7, iPhone 14, and Desktop Chrome in headless Chromium.
#
# This config explicitly excludes Appium, emulator, and BrowserStack tests
# via testIgnore. The webServer block auto-starts MobiSSH on port 8081.
#
# Exit 0 on success, 1 on test failures.

set -euo pipefail
cd "$(dirname "$0")/.."

LOGFILE=/tmp/test-headless.log
exec > >(tee "$LOGFILE") 2>&1

# Compile TypeScript (src/ -> public/modules/) before running browser tests
npx tsc

npx playwright test --config=playwright.config.js
