#!/usr/bin/env bash
# scripts/run-in-repo.sh — Run a command from the repo root
# Usage: scripts/run-in-repo.sh <command> [args...]
# Solves CWD drift when Claude Code process CWD is outside the repo.

set -euo pipefail
cd "$(dirname "$0")/.."
exec "$@"
