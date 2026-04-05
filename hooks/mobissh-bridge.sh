#!/usr/bin/env bash
# Claude Code hook: forward events to MobiSSH via Tailscale.
# For PermissionRequest: blocks until user responds on phone (synchronous gate).
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
  # Synchronous gate: POST and wait for user decision (long-poll, up to 120s).
  # Server holds the connection open until user taps Yes/No on phone.
  RESPONSE=$(curl -sS --max-time 120 -X POST -H 'Content-Type: application/json' \
    -d "$BRIDGE_JSON" \
    "${BRIDGE_URL}/api/approval-gate" 2>/dev/null) || exit 0

  DECISION=$(echo "$RESPONSE" | jq -r '.decision // "deny"' 2>/dev/null)

  # Return hook output that Claude Code understands
  jq -nc --arg decision "$DECISION" '{
    hookSpecificOutput: {
      hookEventName: "PermissionRequest",
      decision: { behavior: $decision }
    }
  }'
else
  # Fire-and-forget for non-approval events
  curl -sS --max-time 3 -X POST -H 'Content-Type: application/json' \
    -d "$BRIDGE_JSON" \
    "${BRIDGE_URL}/api/hook" 2>/dev/null || true
fi
