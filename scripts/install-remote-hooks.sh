#!/usr/bin/env bash
# Install MobiSSH bridge hooks on a remote Claude Code instance.
# curl -sS https://raw.githubusercontent.com/flavordrake/mobissh/main/scripts/install-remote-hooks.sh | bash
set -euo pipefail

BRIDGE="https://mobissh.tailbe5094.ts.net"
HOOK_DIR="${HOME}/.claude/hooks"
HOOK_FILE="${HOOK_DIR}/mobissh-bridge.sh"
HOOK_CMD="~/.claude/hooks/mobissh-bridge.sh"
HOOK_SRC="https://raw.githubusercontent.com/flavordrake/mobissh/main/hooks/mobissh-bridge.sh"
EVENTS=("PermissionRequest" "Stop" "Notification")
GLOBAL="${HOME}/.claude/settings.json"
OK="\033[32m✓\033[0m"
FAIL="\033[31m✗\033[0m"

# Prerequisites
for cmd in curl jq; do command -v $cmd &>/dev/null || { echo -e "$FAIL missing: $cmd"; exit 1; }; done

# Network
curl -sS --max-time 5 -X POST -H 'Content-Type: application/json' \
  -d '{"event":"install-test"}' "${BRIDGE}/api/hook" &>/dev/null \
  || { echo -e "$FAIL cannot reach ${BRIDGE}"; exit 1; }
echo -e "$OK network: ${BRIDGE}"

# Download hook script
mkdir -p "${HOOK_DIR}"
curl -sS --max-time 10 -o "${HOOK_FILE}" "${HOOK_SRC}" \
  || { echo -e "$FAIL download failed: ${HOOK_SRC}"; exit 1; }
chmod +x "${HOOK_FILE}"

# Verify gate endpoint
if grep -q "approval-gate" "${HOOK_FILE}"; then
  echo -e "$OK hook: approval-gate (synchronous)"
else
  echo -e "$FAIL hook: missing approval-gate (stale version)"
  exit 1
fi

# Show hook content summary
echo "   endpoints: $(grep -o 'https://[^ "]*' "${HOOK_FILE}" | sort -u | tr '\n' ' ')"

# Install hooks into settings files
HOOK_ENTRY=$(jq -nc --arg cmd "$HOOK_CMD" '[{"matcher":"","hooks":[{"type":"command","command":$cmd}]}]')

install_to() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local changed=0
  for ev in "${EVENTS[@]}"; do
    local has
    has=$(jq -r ".hooks.${ev} // [] | .[].hooks[]?.command // empty" "$file" 2>/dev/null)
    if echo "$has" | grep -q "mobissh-bridge"; then continue; fi
    local tmp="${file}.tmp.$$"
    jq --argjson entry "$HOOK_ENTRY" ".hooks.${ev} = ((.hooks.${ev} // []) + \$entry)" "$file" > "$tmp"
    mv "$tmp" "$file"
    changed=1
  done
  return 0
}

install_to "$GLOBAL"

# Walk up for project-level configs that define hooks
DIR="$(pwd)"
while [[ "$DIR" != "/" ]]; do
  for f in "${DIR}/.claude/settings.json" "${DIR}/.claude/settings.local.json"; do
    if [[ -f "$f" ]] && jq -e '.hooks' "$f" &>/dev/null; then
      install_to "$f"
    fi
  done
  DIR="$(dirname "$DIR")"
done

# Final state — compact report
echo ""
echo "Config chain:"
for f in "$GLOBAL" "${HOME}/.claude/settings.local.json"; do
  [[ -f "$f" ]] || continue
  label=$(basename "$(dirname "$f")")/$(basename "$f")
  for ev in "${EVENTS[@]}"; do
    cmd=$(jq -r ".hooks.${ev}[]?.hooks[]?.command // empty" "$f" 2>/dev/null | head -1)
    if [[ -n "$cmd" ]]; then
      echo -e "  $OK ${label} ${ev} → ${cmd}"
    else
      echo -e "  $FAIL ${label} ${ev} → (none)"
    fi
  done
done
DIR="$(pwd)"
while [[ "$DIR" != "/" ]]; do
  for f in "${DIR}/.claude/settings.json" "${DIR}/.claude/settings.local.json"; do
    if [[ -f "$f" ]] && jq -e '.hooks' "$f" &>/dev/null; then
      label="${f}"
      for ev in "${EVENTS[@]}"; do
        cmd=$(jq -r ".hooks.${ev}[]?.hooks[]?.command // empty" "$f" 2>/dev/null | head -1)
        if [[ -n "$cmd" ]]; then
          echo -e "  $OK ${label} ${ev} → ${cmd}"
        else
          echo -e "  $FAIL ${label} ${ev} → (none)"
        fi
      done
    fi
  done
  DIR="$(dirname "$DIR")"
done

# End-to-end verification: simulate a PermissionRequest through the gate
echo ""
echo "Verifying approval gate end-to-end..."
TEST_JSON='{"event":"PermissionRequest","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"echo install-verify","description":"Install verification test"}}'
GATE_RESP=$(curl -sS --max-time 10 -X POST -H 'Content-Type: application/json' \
  -d "$TEST_JSON" "${BRIDGE}/api/approval-gate" 2>/dev/null) || {
  echo -e "$FAIL approval-gate unreachable"
  exit 1
}
GATE_ID=$(echo "$GATE_RESP" | jq -r '.requestId // empty' 2>/dev/null)
GATE_AUTO=$(echo "$GATE_RESP" | jq -r '.decision // empty' 2>/dev/null)
if [[ -n "$GATE_AUTO" ]]; then
  echo -e "$OK gate: auto-${GATE_AUTO} (no clients connected — default mode)"
elif [[ -n "$GATE_ID" ]]; then
  echo -e "$OK gate: registered #${GATE_ID} (clients connected, awaiting response)"
  # Clean up: auto-respond so it doesn't linger
  curl -sS --max-time 5 -X POST -H 'Content-Type: application/json' \
    -d "{\"requestId\":\"${GATE_ID}\",\"decision\":\"allow\"}" \
    "${BRIDGE}/api/approval-respond" &>/dev/null
  echo -e "$OK gate: test response sent"
else
  echo -e "$FAIL gate: unexpected response: ${GATE_RESP}"
fi

# Verify the hook script itself works (simulate what Claude Code does)
echo ""
echo "Verifying hook script locally..."
HOOK_OUT=$(echo "$TEST_JSON" | timeout 15 "${HOOK_FILE}" 2>/dev/null) || {
  echo -e "$FAIL hook script failed to execute"
  echo "  Check: chmod +x ${HOOK_FILE} && cat ${HOOK_FILE}"
  exit 1
}
HOOK_DECISION=$(echo "$HOOK_OUT" | jq -r '.hookSpecificOutput.decision.behavior // empty' 2>/dev/null)
if [[ -n "$HOOK_DECISION" ]]; then
  echo -e "$OK hook: returned {behavior: ${HOOK_DECISION}}"
else
  echo -e "$FAIL hook: no valid decision in output"
  echo "  Output was: ${HOOK_OUT}"
fi

echo ""
echo "Done. Restart Claude Code sessions for hooks to take effect."
