#!/usr/bin/env bash
# Claude Code hook: forward all events to MobiSSH via Tailscale.
# Install: copy to ~/.claude/hooks/mobissh-bridge.sh on any machine.
# Requires: curl, jq, Tailscale access to mobissh.tailbe5094.ts.net
set -euo pipefail

INPUT=$(cat)
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)
if [[ -z "$EVENT" ]]; then
  exit 0
fi

# Forward raw hook JSON with event field added
BRIDGE_JSON=$(echo "$INPUT" | jq -c --arg event "$EVENT" '. + {event: $event}' 2>/dev/null)
if [[ -z "$BRIDGE_JSON" ]]; then
  exit 0
fi

# Post to MobiSSH — Tailscale URL (works from any machine on the tailnet)
curl -sS --max-time 3 -X POST -H 'Content-Type: application/json' \
  -d "$BRIDGE_JSON" \
  "https://mobissh.tailbe5094.ts.net/api/hook" 2>/dev/null || true
