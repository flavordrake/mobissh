#!/usr/bin/env bash
# scripts/test-lint.sh — ESLint static analysis
#
# Lints all source directories. Exit 0 on success, 1 on lint errors.
# Warnings do not cause failure (ESLint exits 0 for warnings-only).

set -euo pipefail
cd "$(dirname "$0")/.."

LOGFILE=/tmp/test-lint.log
exec > >(tee "$LOGFILE") 2>&1

npx eslint src/ public/ server/ tests/

# SFTP message type sync check (catches missing router entries)
scripts/test-sftp-sync.sh
