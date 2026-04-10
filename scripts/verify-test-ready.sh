#!/usr/bin/env bash
# scripts/verify-test-ready.sh — Pre-flight check before device/emulator testing.
#
# Verifies that the server is current, the endpoint responds, and advises
# on service worker cache busting. Exits 0 if ready, 1 if not.
#
# Usage: scripts/verify-test-ready.sh [--url <base-url>]
#
# Checks:
#   1. Server process matches HEAD (via server-ctl.sh or container-ctl.sh)
#   2. HTTP GET to /version returns 200 with matching hash
#   3. Prints ?reset=1 URL for service worker cache busting

set -euo pipefail
cd "$(dirname "$0")/.."

BASE_URL="${1:-}"
OK=true

# 1. Check server currency
if scripts/container-ctl.sh status >/dev/null 2>&1; then
  echo "[ok] Production container is current"
elif scripts/server-ctl.sh status >/dev/null 2>&1; then
  echo "[ok] Local server is current"
else
  echo "[FAIL] No server running or server is stale"
  echo "  Run: scripts/container-ctl.sh restart"
  echo "    or: scripts/server-ctl.sh ensure"
  OK=false
fi

# 2. Check HTTP endpoint if URL provided
if [[ -n "$BASE_URL" ]]; then
  VERSION_URL="${BASE_URL%/}/version"
  RESPONSE=$(curl -sS --max-time 5 "$VERSION_URL" 2>/dev/null) || {
    echo "[FAIL] Cannot reach $VERSION_URL"
    OK=false
    RESPONSE=""
  }
  if [[ -n "$RESPONSE" ]]; then
    SERVER_HASH=$(echo "$RESPONSE" | jq -r '.hash // empty' 2>/dev/null)
    HEAD_HASH=$(git rev-parse --short HEAD 2>/dev/null)
    if [[ "$SERVER_HASH" == "$HEAD_HASH" ]]; then
      echo "[ok] Server hash matches HEAD ($SERVER_HASH)"
    else
      echo "[WARN] Server hash $SERVER_HASH != HEAD $HEAD_HASH (stale deploy)"
      OK=false
    fi
  fi

  echo ""
  echo "SW cache bust URL: ${BASE_URL%/}/?reset=1"
fi

if [[ "$OK" == "true" ]]; then
  echo ""
  echo "Ready for testing."
else
  echo ""
  echo "Fix the issues above before testing."
  exit 1
fi
