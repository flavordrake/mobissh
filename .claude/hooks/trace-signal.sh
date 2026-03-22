#!/bin/bash
# PostToolUse hook: detect writes to decision-signal paths and nudge TRACE update.
# Fires on Write and Edit. Does NOT block — returns additionalContext only.
#
# Decision-signal paths:
#   - memory/              (memory updates = captured learning)
#   - .claude/settings*    (permission/config changes = process decisions)
#   - .claude/rules/       (rule updates = policy decisions)
#   - CLAUDE.md            (project context changes)

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

[ -z "$FILE_PATH" ] && exit 0

# Check if file matches a decision-signal path
SIGNAL=""

case "$FILE_PATH" in
  */memory/*|*/.claude/projects/*/memory/*)
    SIGNAL="MEMORY_UPDATE" ;;
  */.claude/settings*.json)
    SIGNAL="SETTINGS_UPDATE" ;;
  */.claude/rules/*)
    SIGNAL="RULE_UPDATE" ;;
  */CLAUDE.md)
    SIGNAL="CONTEXT_UPDATE" ;;
  */.traces/*)
    # Don't signal on TRACE writes themselves — that's the response, not the trigger
    exit 0 ;;
esac

[ -z "$SIGNAL" ] && exit 0

# Find active TRACE from CLAUDE.md if possible
TRACE_DIR=""
if [ -f "CLAUDE.md" ]; then
  TRACE_DIR=$(grep -oP '\.traces/trace-[^\s`/]+/' CLAUDE.md 2>/dev/null | head -1)
fi

CONTEXT="TRACE signal (${SIGNAL}): A decision was just captured in ${FILE_PATH##*/}."
if [ -n "$TRACE_DIR" ]; then
  CONTEXT="${CONTEXT} Active TRACE: ${TRACE_DIR} — consider updating TRACE.md or adding a pivot if strategy changed."
else
  CONTEXT="${CONTEXT} No active TRACE found in CLAUDE.md. Consider initializing one with scripts/trace-init.sh if this is part of a development arc."
fi

jq -n --arg ctx "$CONTEXT" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: $ctx
  }
}'
