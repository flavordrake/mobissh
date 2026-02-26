#!/usr/bin/env bash
# scripts/server-ctl.sh — MobiSSH server lifecycle management
#
# Manages the dev server with health checks, version gating, and
# automatic restart when serving stale code.
#
# Usage:
#   bash scripts/server-ctl.sh start       # start if not running, restart if stale
#   bash scripts/server-ctl.sh stop        # stop server
#   bash scripts/server-ctl.sh restart     # force restart
#   bash scripts/server-ctl.sh status      # health + version check
#   bash scripts/server-ctl.sh ensure      # start or restart until healthy at HEAD
#
# Environment:
#   PORT          — server port (default: 8081)
#   BASE_PATH     — URL base path (default: none)
#   HEALTH_TIMEOUT — seconds to wait for health (default: 10)

set -euo pipefail

PORT="${PORT:-8081}"
BASE_PATH="${BASE_PATH:-}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-10}"
SERVER_CMD="node server/index.js"
LOGFILE="/tmp/mobissh-server-${PORT}.log"
PIDFILE="/tmp/mobissh-server-${PORT}.pid"

# cd to project root (parent of scripts/)
cd "$(dirname "$0")/.."

log() { printf '\033[36m> %s\033[0m\n' "$*"; }
err() { printf '\033[31m! %s\033[0m\n' "$*" >&2; }
ok()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }

# Get the current git HEAD short hash
head_hash() {
  git rev-parse --short HEAD 2>/dev/null || echo "unknown"
}

# Get the version string the server is currently serving
server_version() {
  local url="http://localhost:${PORT}/"
  local html
  html=$(curl -sf --max-time 3 "$url" 2>/dev/null) || { echo ""; return; }
  echo "$html" | grep -oP 'app-version"\s*content="[^"]*"' | grep -oP ':\K[a-f0-9]+' || echo ""
}

# Find the server PID (by port or pidfile)
find_pid() {
  # Try pidfile first
  if [[ -f "$PIDFILE" ]]; then
    local pid
    pid=$(cat "$PIDFILE")
    if kill -0 "$pid" 2>/dev/null; then
      echo "$pid"
      return
    fi
    rm -f "$PIDFILE"
  fi
  # Fall back to lsof
  lsof -ti "tcp:${PORT}" -sTCP:LISTEN 2>/dev/null || true
}

# Check if the server is responding
is_healthy() {
  curl -sf --max-time 2 "http://localhost:${PORT}/" >/dev/null 2>&1
}

# Wait for health with timeout
wait_healthy() {
  local elapsed=0
  while (( elapsed < HEALTH_TIMEOUT )); do
    if is_healthy; then
      return 0
    fi
    sleep 1
    (( elapsed++ ))
  done
  return 1
}

# Check if server version matches HEAD
is_current() {
  local serving head
  serving=$(server_version)
  head=$(head_hash)
  [[ -n "$serving" && "$serving" == "$head" ]]
}

cmd_stop() {
  local pid
  pid=$(find_pid)
  if [[ -z "$pid" ]]; then
    log "No server running on port ${PORT}."
    return 0
  fi
  log "Stopping server (PID ${pid}) on port ${PORT}..."
  kill "$pid" 2>/dev/null || true
  # Wait for port to free
  local tries=0
  while (( tries < 10 )); do
    if ! lsof -ti "tcp:${PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
      break
    fi
    sleep 0.5
    (( tries++ ))
  done
  rm -f "$PIDFILE"
  ok "Server stopped."
}

cmd_start() {
  if is_healthy; then
    if is_current; then
      ok "Server already running at HEAD ($(head_hash)) on port ${PORT}."
      return 0
    else
      log "Server running but stale (serving $(server_version), HEAD is $(head_hash)). Restarting..."
      cmd_stop
    fi
  fi

  log "Starting server on port ${PORT}..."
  local env_args="PORT=${PORT}"
  [[ -n "$BASE_PATH" ]] && env_args="${env_args} BASE_PATH=${BASE_PATH}"

  nohup bash -c "${env_args} ${SERVER_CMD}" > "$LOGFILE" 2>&1 &
  local pid=$!
  echo "$pid" > "$PIDFILE"

  if wait_healthy; then
    local serving
    serving=$(server_version)
    ok "Server started (PID ${pid}, port ${PORT}, version ${serving})."
  else
    err "Server failed to become healthy within ${HEALTH_TIMEOUT}s."
    err "Check log: $LOGFILE"
    return 1
  fi
}

cmd_restart() {
  cmd_stop
  sleep 1
  # Clear any args that cmd_start would interpret as "already running"
  cmd_start
}

cmd_status() {
  local head
  head=$(head_hash)

  if ! is_healthy; then
    err "Server NOT responding on port ${PORT}."
    local pid
    pid=$(find_pid)
    [[ -n "$pid" ]] && err "Process ${pid} exists but not healthy." || err "No process found."
    return 1
  fi

  local serving
  serving=$(server_version)

  if [[ "$serving" == "$head" ]]; then
    ok "Healthy. Serving ${serving} (matches HEAD). Port ${PORT}."
  else
    err "Healthy but STALE. Serving ${serving}, HEAD is ${head}. Run: bash scripts/server-ctl.sh restart"
    return 1
  fi

  local pid
  pid=$(find_pid)
  [[ -n "$pid" ]] && log "PID: ${pid}" || log "PID: (unknown)"
  log "Log: ${LOGFILE}"
}

cmd_ensure() {
  # Start or restart until healthy and at HEAD. Idempotent.
  if is_healthy && is_current; then
    ok "Server healthy at HEAD ($(head_hash)) on port ${PORT}."
    return 0
  fi
  cmd_start
}

case "${1:-}" in
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  restart) cmd_restart ;;
  status)  cmd_status ;;
  ensure)  cmd_ensure ;;
  *)
    echo "Usage: bash scripts/server-ctl.sh {start|stop|restart|status|ensure}"
    echo ""
    echo "  start    Start if not running, restart if stale"
    echo "  stop     Stop the server"
    echo "  restart  Force restart"
    echo "  status   Health check + version gate"
    echo "  ensure   Idempotent: start or restart until healthy at HEAD"
    exit 1
    ;;
esac
