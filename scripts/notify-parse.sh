#!/bin/bash
# Parses Claude Code hook event JSON and outputs a clean, actionable notification string.
# Input: JSON on stdin (from Claude Code hook event)
# Output: single-line notification text (max 80 chars) on stdout
#
# Used by ~/.claude/hooks/notify-bell.sh to format terminal notifications.

set -euo pipefail

INPUT=$(cat)

# Require jq
if ! command -v jq &>/dev/null; then
  exit 0
fi

EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)
MSG=""

case "$EVENT" in
  PermissionRequest)
    TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
    if [[ -z "$TOOL" ]]; then
      exit 0
    fi
    MSG="Approve: $TOOL"

    # Extract the most relevant target from tool_input
    CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
    FPATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    PATTERN=$(echo "$INPUT" | jq -r '.tool_input.pattern // empty' 2>/dev/null)

    TARGET=""
    if [[ -n "$CMD" ]]; then
      # For commands, take first 60 chars
      TARGET="${CMD:0:60}"
    elif [[ -n "$FPATH" ]]; then
      # For file paths, use basename to keep it short
      TARGET=$(basename "$FPATH")
    elif [[ -n "$PATTERN" ]]; then
      TARGET="${PATTERN:0:60}"
    fi

    if [[ -n "$TARGET" ]]; then
      MSG="$MSG — $TARGET"
    fi
    ;;

  Notification)
    TITLE=$(echo "$INPUT" | jq -r '.title // empty' 2>/dev/null)
    MESSAGE=$(echo "$INPUT" | jq -r '.message // empty' 2>/dev/null)

    # Strip ANSI escape sequences
    MESSAGE=$(echo "$MESSAGE" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g')
    TITLE=$(echo "$TITLE" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g')

    # Strip unicode box-drawing characters (U+2500-U+257F)
    MESSAGE=$(echo "$MESSAGE" | sed 's/[╔╗╚╝═║─│┌┐└┘├┤┬┴┼]//g')
    TITLE=$(echo "$TITLE" | sed 's/[╔╗╚╝═║─│┌┐└┘├┤┬┴┼]//g')

    # Strip middle dot (·) used as separator in boilerplate
    MESSAGE=$(echo "$MESSAGE" | sed 's/·//g')

    # Collapse multiple spaces to single space and trim
    MESSAGE=$(echo "$MESSAGE" | sed 's/  */ /g; s/^ *//; s/ *$//')
    TITLE=$(echo "$TITLE" | sed 's/  */ /g; s/^ *//; s/ *$//')

    if [[ -n "$TITLE" && -n "$MESSAGE" ]]; then
      MSG="$TITLE: $MESSAGE"
    elif [[ -n "$MESSAGE" ]]; then
      MSG="$MESSAGE"
    elif [[ -n "$TITLE" ]]; then
      MSG="$TITLE"
    fi
    ;;

  Stop)
    MSG="Claude finished"
    ;;

  *)
    # Unknown event — try message field as fallback
    MESSAGE=$(echo "$INPUT" | jq -r '.message // empty' 2>/dev/null)
    if [[ -n "$MESSAGE" ]]; then
      MSG="${MESSAGE:0:80}"
    fi
    ;;
esac

# Truncate to 80 chars
if [[ ${#MSG} -gt 80 ]]; then
  MSG="${MSG:0:77}..."
fi

echo "$MSG"
