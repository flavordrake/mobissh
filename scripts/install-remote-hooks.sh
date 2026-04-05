#!/usr/bin/env bash
# Install MobiSSH bridge hooks on a remote Claude Code instance.
# Run on any Tailscale-connected machine to forward approvals, stops,
# and notifications to your phone via MobiSSH.
#
# Usage: curl -sS https://raw.githubusercontent.com/flavordrake/mobissh/main/scripts/install-remote-hooks.sh | bash
#   or:  bash <(curl -sS https://raw.githubusercontent.com/flavordrake/mobissh/main/scripts/install-remote-hooks.sh)

set -euo pipefail

HOOK_DIR="${HOME}/.claude/hooks"
HOOK_FILE="${HOOK_DIR}/mobissh-bridge.sh"
BRIDGE_URL="https://mobissh.tailbe5094.ts.net/api/hook"

echo "Installing MobiSSH bridge hooks..."

# Verify Tailscale reachability
if ! curl -sS --max-time 5 -o /dev/null -w '' "${BRIDGE_URL}" -X POST -H 'Content-Type: application/json' -d '{"event":"install-test"}' 2>/dev/null; then
  echo "ERROR: Cannot reach ${BRIDGE_URL}"
  echo "Is Tailscale running? Is mobissh-prod up?"
  exit 1
fi
echo "  Tailscale reachable"

# Install hook script
mkdir -p "${HOOK_DIR}"
cat > "${HOOK_FILE}" << 'HOOKSCRIPT'
#!/usr/bin/env bash
set -euo pipefail
INPUT=$(cat)
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)
[[ -z "$EVENT" ]] && exit 0
BRIDGE_JSON=$(echo "$INPUT" | jq -c --arg event "$EVENT" '. + {event: $event}' 2>/dev/null)
[[ -z "$BRIDGE_JSON" ]] && exit 0
curl -sS --max-time 3 -X POST -H 'Content-Type: application/json' \
  -d "$BRIDGE_JSON" "https://mobissh.tailbe5094.ts.net/api/hook" 2>/dev/null || true
HOOKSCRIPT
chmod +x "${HOOK_FILE}"
echo "  Hook script installed: ${HOOK_FILE}"

# Check for jq
if ! command -v jq &>/dev/null; then
  echo "WARNING: jq not found — hook needs jq to parse Claude Code events"
  echo "  Install: sudo apt install jq  OR  brew install jq"
fi

# Configure Claude Code hooks
if ! command -v claude &>/dev/null; then
  echo "WARNING: claude CLI not found — configure hooks manually in ~/.claude/settings.json"
  echo "  See: https://github.com/flavordrake/mobissh/blob/main/hooks/mobissh-bridge.sh"
  exit 0
fi

HOOK_JSON='[{"matcher":"","hooks":[{"type":"command","command":"~/.claude/hooks/mobissh-bridge.sh"}]}]'
claude config set hooks.PermissionRequest "${HOOK_JSON}"
claude config set hooks.Stop "${HOOK_JSON}"
claude config set hooks.Notification "${HOOK_JSON}"
echo "  Claude Code hooks configured"

echo "Done. Approvals from this machine will appear on your phone."
