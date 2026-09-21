#!/usr/bin/env bash
# scripts/test-infra.sh — the repo's infrastructure unit tests (#1205).
#
# These cover live, non-Flutter infrastructure that survived the PWA retirement:
#   server/feedback-guard.js + server-feedback/index.js  (bug-report ingestion)
#   server/manifest.js                                   (manifest rewriting)
#   scripts/notify-parse.sh                              (attention notifications)
#   scripts/trace-*.sh                                   (TRACE tooling)
#   scripts/termux-bootstrap.sh                          (published curl|bash installer)
#
# Runner is node:test, NOT vitest: agent worktrees have no node_modules (it is
# gitignored and never copied), so a gate step that needs npm deps is exactly
# unrunnable where agents gate. node --test needs nothing but node.
#
# Usage: scripts/test-infra.sh [extra node --test args]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v node >/dev/null 2>&1; then
  echo "! test-infra: node not found on PATH" >&2
  exit 1
fi

echo "> test-infra: node --test test/infra/ (node $(node --version))"
exec node --test "$@" test/infra/
