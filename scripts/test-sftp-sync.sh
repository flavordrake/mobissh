#!/usr/bin/env bash
# scripts/test-sftp-sync.sh — Verify SFTP message types are in sync
#
# Extracts sftp_* types from all landmark locations and ensures they match.
# Catches the exact bug from #233 where sftp_realpath was added to the handler
# but missing from the WS router.
#
# Exit 0 if all in sync, 1 if mismatch found.

set -euo pipefail
cd "$(dirname "$0")/.."

FAIL=0

extract() {
  local file="$1" label="$2" pattern="$3"
  grep -A50 "$label" "$file" \
    | grep -oP "$pattern" \
    | sort -u
}

# Server: handler switch cases
HANDLER=$(extract server/index.js 'SFTP_HANDLER' "case 'sftp_\w+'")
# Server: router switch cases
ROUTER=$(extract server/index.js 'SFTP_ROUTER' "case 'sftp_\w+'")

# Client: SftpMsg Extract type
SFTP_MSG=$(grep -oP "sftp_\w+" src/modules/connection.ts | grep -v 'sftp_handler' | sort -u)
# Client: router switch cases
CLIENT_ROUTER=$(extract src/modules/connection.ts 'SFTP_CLIENT_ROUTER' "case 'sftp_\w+'")

# Types: ServerMessage union
SERVER_MSG=$(grep -oP "sftp_\w+" src/modules/types.ts | sort -u)

check() {
  local name_a="$1" name_b="$2" list_a="$3" list_b="$4"
  local diff_out
  diff_out=$(diff <(echo "$list_a") <(echo "$list_b") || true)
  if [[ -n "$diff_out" ]]; then
    echo "MISMATCH: $name_a vs $name_b"
    echo "$diff_out" | head -10
    echo ""
    FAIL=1
  fi
}

# Server handler must match server router
check "SFTP_HANDLER (server/index.js)" "SFTP_ROUTER (server/index.js)" "$HANDLER" "$ROUTER"

# Server handler must match client types (adding sftp_error which is in types but not a handler case)
HANDLER_PLUS_ERROR=$(printf '%s\ncase '"'"'sftp_error'"'"'' "$HANDLER" | sort -u)
# Normalize: extract just the type names for cross-language comparison
handler_types=$(echo "$HANDLER" | grep -oP "sftp_\w+" | sort -u)
router_types=$(echo "$ROUTER" | grep -oP "sftp_\w+" | sort -u)
client_router_types=$(echo "$CLIENT_ROUTER" | grep -oP "sftp_\w+" | sort -u)

# Server handler types should match server router types
check "SFTP_HANDLER types" "SFTP_ROUTER types" "$handler_types" "$router_types"

# Client types.ts must include all sftp_* server-to-client message types.
# These are result types (_result), streaming types (_meta, _chunk, _end, _ack), and sftp_error.
# The handler→result naming convention is 1:1 for simple operations but N:1 for streaming.
# Instead of inferring result types from handler names, just verify all types.ts sftp types
# are present in the client router and SftpMsg Extract.

# All sftp types defined in types.ts ServerMessage (server-to-client messages)
types_sftp=$(echo "$SERVER_MSG" | sort -u)

# Client router should handle all sftp types from types.ts
for t in $types_sftp; do
  if ! echo "$client_router_types" | grep -q "^${t}$" 2>/dev/null; then
    echo "MISSING: ${t} not in connection.ts SFTP_CLIENT_ROUTER"
    FAIL=1
  fi
done

# SftpMsg Extract type should include all sftp types from types.ts
for t in $types_sftp; do
  if ! echo "$SFTP_MSG" | grep -q "^${t}$" 2>/dev/null; then
    echo "MISSING: ${t} not in connection.ts SFTP_MSG type"
    FAIL=1
  fi
done

if [[ "$FAIL" -eq 0 ]]; then
  echo "SFTP types in sync ($(echo "$handler_types" | wc -l | tr -d ' ') operations)"
else
  echo "SFTP type sync check FAILED"
  exit 1
fi
