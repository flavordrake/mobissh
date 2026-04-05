#!/usr/bin/env bash
# Claude Code hook: forward events to MobiSSH via Tailscale.
# For PermissionRequest: registers gate, polls for user decision.
# For other events: fire-and-forget notification.
#
# Install: copy to ~/.claude/hooks/mobissh-bridge.sh on any machine.
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

if [[ "$EVENT" == "PermissionRequest" ]]; then
  # Register the gate and get a requestId back immediately
  REG=$(curl -sS --max-time 10 -X POST -H 'Content-Type: application/json' \
    -d "$BRIDGE_JSON" \
    "${BRIDGE_URL}/api/approval-gate" 2>/dev/null) || exit 0

  REQUEST_ID=$(echo "$REG" | jq -r '.requestId // empty' 2>/dev/null)
  if [[ -z "$REQUEST_ID" ]]; then
    exit 0
  fi

  # Check if server auto-approved (no clients connected)
  AUTO=$(echo "$REG" | jq -r '.decision // empty' 2>/dev/null)
  if [[ -n "$AUTO" ]]; then
    jq -nc --arg decision "$AUTO" '{
      hookSpecificOutput: {
        hookEventName: "PermissionRequest",
        decision: { behavior: $decision }
      }
    }'
    exit 0
  fi

  # Poll for the user's decision (2s interval, up to 120s)
  DEADLINE=$((SECONDS + 120))
  while [[ $SECONDS -lt $DEADLINE ]]; do
    sleep 2
    POLL=$(curl -sS --max-time 5 \
      "${BRIDGE_URL}/api/approval-poll?id=${REQUEST_ID}" 2>/dev/null) || continue
    STATUS=$(echo "$POLL" | jq -r '.status // "pending"' 2>/dev/null)
    if [[ "$STATUS" != "pending" ]]; then
      DECISION=$(echo "$POLL" | jq -r '.decision // "allow"' 2>/dev/null)
      jq -nc --arg decision "$DECISION" '{
        hookSpecificOutput: {
          hookEventName: "PermissionRequest",
          decision: { behavior: $decision }
        }
      }'
      exit 0
    fi
  done

  # Timeout — default approve (user chose not to deny)
  jq -nc '{ hookSpecificOutput: { hookEventName: "PermissionRequest", decision: { behavior: "allow" } } }'
else
  # Fire-and-forget for non-approval events
  curl -sS --max-time 3 -X POST -H 'Content-Type: application/json' \
    -d "$BRIDGE_JSON" \
    "${BRIDGE_URL}/api/hook" 2>/dev/null || true
fi
