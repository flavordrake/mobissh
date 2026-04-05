#!/usr/bin/env bash
# Claude Code hook: MobiSSH approval bridge.
#
# For PermissionRequest:
#   1. Check server for user's default mode (allow/deny)
#   2. If server unreachable, use the default mode
#   3. If server reachable and clients connected, register gate and poll
#   4. If server reachable but no clients, use default mode immediately
#   5. On timeout, use default mode
#
# For other events: fire-and-forget notification.
#
# Install: scripts/install-remote-hooks.sh
# Requires: curl, jq, Tailscale access to mobissh.tailbe5094.ts.net
set -euo pipefail

BRIDGE_URL="https://mobissh.tailbe5094.ts.net"
INPUT=$(cat)
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)
if [[ -z "$EVENT" ]]; then
  exit 0
fi

BRIDGE_JSON=$(echo "$INPUT" | jq -c --arg event "$EVENT" '. + {event: $event}' 2>/dev/null)
if [[ -z "$BRIDGE_JSON" ]]; then
  exit 0
fi

# Helper: output a hook decision
emit_decision() {
  local decision="$1"
  jq -nc --arg decision "$decision" '{
    hookSpecificOutput: {
      hookEventName: "PermissionRequest",
      decision: { behavior: $decision }
    }
  }'
}

if [[ "$EVENT" == "PermissionRequest" ]]; then
  # Step 1: Register gate and get server response
  REG=$(curl -sS --max-time 10 -X POST -H 'Content-Type: application/json' \
    -d "$BRIDGE_JSON" \
    "${BRIDGE_URL}/api/approval-gate" 2>/dev/null) || {
    # Server unreachable — emit allow (default safe mode)
    emit_decision "allow"
    exit 0
  }

  # Step 2: Check if server auto-decided (no clients, or immediate decision)
  AUTO=$(echo "$REG" | jq -r '.decision // empty' 2>/dev/null)
  if [[ -n "$AUTO" ]]; then
    emit_decision "$AUTO"
    exit 0
  fi

  # Step 3: Got a requestId — poll for user's decision
  REQUEST_ID=$(echo "$REG" | jq -r '.requestId // empty' 2>/dev/null)
  if [[ -z "$REQUEST_ID" ]]; then
    emit_decision "allow"
    exit 0
  fi

  # Step 4: Poll (2s interval, 115s — shorter than server's 120s to avoid race)
  DEADLINE=$((SECONDS + 115))
  while [[ $SECONDS -lt $DEADLINE ]]; do
    sleep 2
    POLL=$(curl -sS --max-time 5 \
      "${BRIDGE_URL}/api/approval-poll?id=${REQUEST_ID}" 2>/dev/null) || continue
    STATUS=$(echo "$POLL" | jq -r '.status // "pending"' 2>/dev/null)
    if [[ "$STATUS" != "pending" ]]; then
      DECISION=$(echo "$POLL" | jq -r '.decision // "allow"' 2>/dev/null)
      emit_decision "$DECISION"
      exit 0
    fi
  done

  # Step 5: Timeout — default allow
  emit_decision "allow"
else
  # Fire-and-forget for non-approval events
  curl -sS --max-time 3 -X POST -H 'Content-Type: application/json' \
    -d "$BRIDGE_JSON" \
    "${BRIDGE_URL}/api/hook" 2>/dev/null || true
fi
