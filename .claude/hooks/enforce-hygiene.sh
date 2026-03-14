#!/bin/bash
# PreToolUse hook: remind Claude to prefer scripts over ad-hoc bash.
# Detects redirects, pipes, compound commands, heredocs, and raw gh.
# Returns additionalContext as a nudge — does NOT block execution.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

[ -z "$COMMAND" ] && exit 0

WARNINGS=""

# Shell redirects: > >> 2> but NOT --> or => (flags/arrows)
if echo "$COMMAND" | grep -qP '(?<![=-])\s*[12]?>|>>|\s+&>'; then
  WARNINGS="${WARNINGS}REDIRECT: Scripts handle their own output. Is a redirect needed here? "
fi

# Pipes
if echo "$COMMAND" | grep -qP '\|(?!\|)'; then
  WARNINGS="${WARNINGS}PIPE: Could this be a script instead of piped commands? "
fi

# Compound && chains
if echo "$COMMAND" | grep -qF '&&'; then
  WARNINGS="${WARNINGS}CHAIN: One script per Bash call. Look for or create a wrapper script. "
fi

# Semicolon sequences
if echo "$COMMAND" | grep -qP ';\s*\w'; then
  WARNINGS="${WARNINGS}SEMICOLON: One command per Bash call. "
fi

# Heredocs
if echo "$COMMAND" | grep -qF '<<'; then
  WARNINGS="${WARNINGS}HEREDOC: Use the Write tool + --body-file instead. "
fi

# Raw gh commands
if echo "$COMMAND" | grep -qP '^\s*gh\s'; then
  WARNINGS="${WARNINGS}RAW_GH: Use scripts/gh-ops.sh or scripts/gh-file-issue.sh. "
fi

# /dev/null suppression
if echo "$COMMAND" | grep -qF '/dev/null'; then
  WARNINGS="${WARNINGS}DEVNULL: Keep output — storage is cheap. "
fi

# If any warnings, add context but allow execution
if [ -n "$WARNINGS" ]; then
  jq -n --arg warnings "$WARNINGS" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      additionalContext: ("Command hygiene reminder: " + $warnings + "Check if scripts/ has a wrapper. Create one if this pattern repeats.")
    }
  }'
  exit 0
fi

exit 0
