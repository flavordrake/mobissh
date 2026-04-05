#!/usr/bin/env bash
# Install MobiSSH bridge hooks on a remote Claude Code instance.
# Walks the full config chain, diagnoses conflicts, installs at every level needed.
#
# Usage: curl -sS https://raw.githubusercontent.com/flavordrake/mobissh/main/scripts/install-remote-hooks.sh | bash

set -euo pipefail

BRIDGE_URL="https://mobissh.tailbe5094.ts.net/api/hook"
HOOK_DIR="${HOME}/.claude/hooks"
HOOK_FILE="${HOOK_DIR}/mobissh-bridge.sh"
HOOK_CMD="~/.claude/hooks/mobissh-bridge.sh"
EVENTS=("PermissionRequest" "Stop" "Notification")

echo "MobiSSH bridge hook installer"
echo ""

# 1. Check prerequisites
MISSING=""
command -v curl &>/dev/null || MISSING="curl "
command -v jq &>/dev/null || MISSING="${MISSING}jq "
if [[ -n "$MISSING" ]]; then
  echo "ERROR: missing required tools: ${MISSING}"
  echo "  Install: sudo apt install ${MISSING} OR brew install ${MISSING}"
  exit 1
fi
echo "[ok] Prerequisites: curl, jq"

# 2. Verify Tailscale reachability
if curl -sS --max-time 5 -X POST -H 'Content-Type: application/json' \
  -d '{"event":"install-test"}' "${BRIDGE_URL}" &>/dev/null; then
  echo "[ok] MobiSSH reachable at ${BRIDGE_URL}"
else
  echo "ERROR: Cannot reach ${BRIDGE_URL}"
  echo "  Is Tailscale running? Is mobissh-prod up?"
  exit 1
fi

# 3. Install hook script — download from repo (single source of truth)
mkdir -p "${HOOK_DIR}"
HOOK_URL="https://raw.githubusercontent.com/flavordrake/mobissh/main/hooks/mobissh-bridge.sh"
if curl -sS --max-time 10 -o "${HOOK_FILE}" "${HOOK_URL}"; then
  chmod +x "${HOOK_FILE}"
  echo "[ok] Hook script downloaded: ${HOOK_FILE}"
else
  echo "ERROR: Failed to download hook script from ${HOOK_URL}"
  exit 1
fi

# Verify the hook uses the gate endpoint (not the old fire-and-forget path)
if grep -q "approval-gate" "${HOOK_FILE}"; then
  echo "[ok] Hook uses synchronous approval gate"
else
  echo "WARNING: Hook does NOT use approval-gate — approvals will be fire-and-forget"
  echo "  Check ${HOOK_URL} for the latest version"
fi

# 4. Scan config chain for existing hooks that might override
GLOBAL_SETTINGS="${HOME}/.claude/settings.json"
GLOBAL_LOCAL="${HOME}/.claude/settings.local.json"

echo ""
echo "Scanning config chain..."

scan_hooks() {
  local file="$1"
  local label="$2"
  if [[ ! -f "$file" ]]; then
    echo "  ${label}: (not found)"
    return
  fi
  local has_hooks
  has_hooks=$(jq -r 'if .hooks then "yes" else "no" end' "$file" 2>/dev/null)
  if [[ "$has_hooks" != "yes" ]]; then
    echo "  ${label}: no hooks defined"
    return
  fi
  echo "  ${label}: has hooks"
  for ev in "${EVENTS[@]}"; do
    local count
    count=$(jq -r ".hooks.${ev} // [] | length" "$file" 2>/dev/null)
    if [[ "$count" -gt 0 ]]; then
      local cmds
      cmds=$(jq -r ".hooks.${ev}[]?.hooks[]?.command // empty" "$file" 2>/dev/null)
      echo "    ${ev}: ${count} handler(s) — ${cmds}"
    else
      echo "    ${ev}: (none)"
    fi
  done
}

scan_hooks "$GLOBAL_SETTINGS" "Global (~/.claude/settings.json)"
scan_hooks "$GLOBAL_LOCAL" "Global local (~/.claude/settings.local.json)"

# Scan project-level configs (walk up from CWD)
PROJECT_CONFIGS=()
DIR="$(pwd)"
while [[ "$DIR" != "/" ]]; do
  for f in "${DIR}/.claude/settings.json" "${DIR}/.claude/settings.local.json"; do
    if [[ -f "$f" ]]; then
      PROJECT_CONFIGS+=("$f")
      scan_hooks "$f" "Project (${f})"
    fi
  done
  DIR="$(dirname "$DIR")"
done

# 5. Install hooks — global settings.json with jq (doesn't clobber existing hooks)
echo ""
echo "Installing hooks..."

HOOK_ENTRY=$(jq -nc --arg cmd "$HOOK_CMD" '[{"matcher":"","hooks":[{"type":"command","command":$cmd}]}]')

install_hooks_jq() {
  local file="$1"
  local label="$2"
  local tmp="${file}.tmp.$$"

  if [[ ! -f "$file" ]]; then
    # Create with just hooks
    jq -nc --argjson pr "$HOOK_ENTRY" --argjson stop "$HOOK_ENTRY" --argjson notif "$HOOK_ENTRY" \
      '{hooks:{PermissionRequest:$pr,Stop:$stop,Notification:$notif}}' > "$tmp"
    mv "$tmp" "$file"
    echo "  ${label}: created with hooks"
    return
  fi

  # Merge hooks into existing file, preserving other settings
  local updated="$file"
  for ev in "${EVENTS[@]}"; do
    # Check if mobissh-bridge is already in this event's hooks
    local already
    already=$(jq -r ".hooks.${ev} // [] | .[].hooks[]?.command // empty" "$file" 2>/dev/null)
    if echo "$already" | grep -q "mobissh-bridge"; then
      echo "  ${label}: ${ev} already has mobissh-bridge"
      continue
    fi
    # Add our hook entry (append to existing array or create)
    jq --argjson entry "$HOOK_ENTRY" ".hooks.${ev} = ((.hooks.${ev} // []) + \$entry)" "$file" > "$tmp"
    mv "$tmp" "$file"
    echo "  ${label}: ${ev} added"
  done
}

install_hooks_jq "$GLOBAL_SETTINGS" "Global"

# Also install into any project-level configs that define hooks
# (project hooks override global — if they exist without our hook, approvals get lost)
for pconfig in "${PROJECT_CONFIGS[@]}"; do
  has_hooks=$(jq -r 'if .hooks then "yes" else "no" end' "$pconfig" 2>/dev/null)
  if [[ "$has_hooks" == "yes" ]]; then
    install_hooks_jq "$pconfig" "Project (${pconfig})"
  fi
done

# 6. Verify final state
echo ""
echo "Verifying..."
scan_hooks "$GLOBAL_SETTINGS" "Global (final)"
for pconfig in "${PROJECT_CONFIGS[@]}"; do
  scan_hooks "$pconfig" "Project (${pconfig}, final)"
done

# 7. Send test event
echo ""
curl -sS --max-time 3 -X POST -H 'Content-Type: application/json' \
  -d '{"event":"install-verified","hook_event_name":"Notification"}' \
  "${BRIDGE_URL}" &>/dev/null
echo "[ok] Test event sent — check your phone for 'install-verified'"
echo ""
echo "Done. Approvals from this machine will appear on your phone."
echo "Restart any running Claude Code sessions for hooks to take effect."
