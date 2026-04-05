#!/usr/bin/env bash
# Lightweight HTTP listener on port 9099 that creates GitHub issues
# from bug reports relayed by the MobiSSH production container.
#
# Runs on fd-dev (dev container) which has gh CLI authenticated.
# Start: scripts/bug-report-listener.sh &
# Stop:  kill $(cat /tmp/mobissh/bug-report-listener.pid)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT=9099
MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
PIDFILE="${MOBISSH_TMPDIR}/bug-report-listener.pid"

mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"

# Check if already running
if [[ -f "$PIDFILE" ]]; then
  OLD_PID=$(cat "$PIDFILE")
  if kill -0 "$OLD_PID" 2>/dev/null; then
    echo "Already running (PID $OLD_PID)"
    exit 0
  fi
fi

# Requires socat for the HTTP listener
if ! command -v socat &>/dev/null; then
  echo "ERROR: socat not found. Install: apt install socat"
  exit 1
fi

echo "Starting bug report listener on port $PORT..."
echo $$ > "$PIDFILE"

handle_request() {
  # Read HTTP request
  read -r REQUEST_LINE
  CONTENT_LENGTH=0
  while IFS= read -r HEADER; do
    HEADER=$(echo "$HEADER" | tr -d '\r')
    [[ -z "$HEADER" ]] && break
    if [[ "$HEADER" =~ ^[Cc]ontent-[Ll]ength:\ ([0-9]+) ]]; then
      CONTENT_LENGTH=${BASH_REMATCH[1]}
    fi
  done

  BODY=""
  if [[ "$CONTENT_LENGTH" -gt 0 ]]; then
    BODY=$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)
  fi

  # Parse JSON
  TITLE=$(echo "$BODY" | jq -r '.title // "Bug report"' 2>/dev/null)
  LABEL=$(echo "$BODY" | jq -r '.label // "bug"' 2>/dev/null)

  # Write body to temp file
  BODY_FILE="${MOBISSH_TMPDIR}/issue-body-$$.md"
  echo "$BODY" | jq -r '.body // "No body"' > "$BODY_FILE" 2>/dev/null

  # Create issue
  ISSUE_URL=""
  if command -v gh &>/dev/null; then
    ISSUE_URL=$(gh issue create --repo flavordrake/mobissh \
      --title "$TITLE" \
      --body-file "$BODY_FILE" \
      --label "$LABEL" 2>&1) || ISSUE_URL="error: $ISSUE_URL"
    echo "[bug-report-listener] created: $ISSUE_URL" >> "${MOBISSH_LOGDIR}/bug-report.log"
  else
    ISSUE_URL="error: gh not found"
  fi

  rm -f "$BODY_FILE"

  # HTTP response
  RESPONSE="{\"issueUrl\":\"$ISSUE_URL\"}"
  echo -e "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${#RESPONSE}\r\nConnection: close\r\n\r\n$RESPONSE"
}

export -f handle_request
export MOBISSH_TMPDIR MOBISSH_LOGDIR

exec socat TCP-LISTEN:${PORT},reuseaddr,fork SYSTEM:"bash -c handle_request"
