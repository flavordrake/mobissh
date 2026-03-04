#!/usr/bin/env bash
# scripts/test-status.sh — Show running test infrastructure
#
# Reports what test processes, servers, and emulators are currently active.
# Useful for debugging stale processes, checking if gates are still running,
# or verifying infrastructure before launching tests.
#
# Usage: scripts/test-status.sh

set -euo pipefail

section() { echo "[$1]"; }

section "Playwright"
PW=$(pgrep -af "playwright" 2>/dev/null | grep -v grep || true)
if [ -n "$PW" ]; then
  echo "$PW" | while read -r line; do echo "  $line"; done
else
  echo "  not running"
fi

section "Vitest"
VT=$(pgrep -af "vitest" 2>/dev/null | grep -v grep || true)
if [ -n "$VT" ]; then
  echo "$VT" | while read -r line; do echo "  $line"; done
else
  echo "  not running"
fi

section "Appium"
AP=$(pgrep -af "appium" 2>/dev/null | grep -v grep || true)
if [ -n "$AP" ]; then
  echo "$AP" | while read -r line; do echo "  $line"; done
else
  echo "  not running"
fi

section "MobiSSH server"
SRV=$(pgrep -af "node.*server/index.js" 2>/dev/null | grep -v grep || true)
if [ -n "$SRV" ]; then
  echo "$SRV" | while read -r line; do echo "  $line"; done
else
  echo "  not running"
fi

section "Android emulator"
EMU=$(pgrep -af "qemu.*android\|emulator" 2>/dev/null | grep -v grep || true)
if [ -n "$EMU" ]; then
  echo "$EMU" | while read -r line; do echo "  $line"; done
else
  echo "  not running"
fi

section "Docker (test sshd)"
if command -v docker &>/dev/null; then
  DC=$(docker ps --filter "name=sshd" --format "  {{.Names}} ({{.Status}})" 2>/dev/null || true)
  if [ -n "$DC" ]; then
    echo "$DC"
  else
    echo "  not running"
  fi
else
  echo "  docker not available"
fi

section "Git worktrees"
WT=$(git worktree list 2>/dev/null | grep -v "$(git rev-parse --show-toplevel)$" || true)
if [ -n "$WT" ]; then
  echo "$WT" | while read -r line; do echo "  $line"; done
else
  echo "  none (main only)"
fi
