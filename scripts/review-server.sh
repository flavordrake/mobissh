#!/usr/bin/env bash
# scripts/review-server.sh — Test review server lifecycle management
#
# Manages the review server that serves test results, recordings, frames,
# and device uploads for mobile review on port 9090.
#
# Usage:
#   scripts/review-server.sh start       # start if not running
#   scripts/review-server.sh stop        # stop server
#   scripts/review-server.sh restart     # force restart
#   scripts/review-server.sh status      # health check
#   scripts/review-server.sh ensure      # start if not running (idempotent)
#
# Environment:
#   REVIEW_PORT     — server port (default: 9090)
#   HEALTH_TIMEOUT  — seconds to wait for health (default: 5)

set -euo pipefail

PORT="${REVIEW_PORT:-9090}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-5}"
MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"
LOGFILE="${MOBISSH_LOGDIR}/review-server.log"
PIDFILE="${MOBISSH_TMPDIR}/review-server.pid"

# cd to project root (parent of scripts/)
cd "$(dirname "$0")/.."

SERVER="tools/review-server/serve.js"

log() { echo "> $*"; }
err() { echo "! $*" >&2; }
ok()  { echo "+ $*"; }

# Find PID listening on a port via ss (lsof not available in this container)
pid_on_port() {
  local port=$1
  ss -tlnp "sport = :${port}" 2>/dev/null \
    | grep -oP 'pid=\K[0-9]+' \
    | head -1 \
    || true
}

# Find the server PID (by pidfile or port scan)
find_pid() {
  if [[ -f "$PIDFILE" ]]; then
    local pid
    pid=$(cat "$PIDFILE")
    if kill -0 "$pid" 2>/dev/null; then
      echo "$pid"
      return
    fi
    rm -f "$PIDFILE"
  fi
  pid_on_port "$PORT"
}

is_healthy() {
  curl -sf --max-time 2 "http://localhost:${PORT}/" >/dev/null 2>&1
}

wait_healthy() {
  local elapsed=0
  while (( elapsed < HEALTH_TIMEOUT )); do
    if is_healthy; then return 0; fi
    sleep 1
    (( elapsed++ ))
  done
  return 1
}

cmd_stop() {
  local pid
  pid=$(find_pid)
  if [[ -z "$pid" ]]; then
    log "No review server running on port ${PORT}."
    return 0
  fi
  log "Stopping review server (PID ${pid}) on port ${PORT}..."
  kill "$pid" 2>/dev/null || true
  local tries=0
  while (( tries < 10 )); do
    if [[ -z "$(pid_on_port "$PORT")" ]]; then
      break
    fi
    sleep 0.5
    (( tries++ ))
  done
  rm -f "$PIDFILE"
  ok "Review server stopped."
}

cmd_start() {
  if is_healthy; then
    ok "Review server already running on port ${PORT}."
    return 0
  fi

  # Kill any stale process on the port (e.g. old screenshot server)
  local stale_pid
  stale_pid=$(pid_on_port "$PORT")
  if [[ -n "$stale_pid" ]]; then
    log "Killing stale process on port ${PORT} (PID ${stale_pid})..."
    kill "$stale_pid" 2>/dev/null || true
    sleep 1
  fi

  [[ -f "$SERVER" ]] || { err "Server not found: $SERVER"; return 1; }

  log "Starting review server on port ${PORT}..."
  nohup node "$SERVER" --port "$PORT" >> "$LOGFILE" 2>&1 &
  local pid=$!
  echo "$pid" > "$PIDFILE"

  if wait_healthy; then
    ok "Review server started (PID ${pid}) on port ${PORT}."
    ok "URL: http://localhost:${PORT}"
  else
    err "Review server failed to start within ${HEALTH_TIMEOUT}s."
    err "Check log: $LOGFILE"
    return 1
  fi
}

cmd_restart() {
  cmd_stop
  sleep 1
  cmd_start
}

cmd_status() {
  if ! is_healthy; then
    local pid
    pid=$(find_pid)
    if [[ -n "$pid" ]]; then
      err "Process ${pid} exists but not healthy on port ${PORT}."
    else
      err "Review server NOT running on port ${PORT}."
    fi
    return 1
  fi

  local pid
  pid=$(find_pid)
  ok "Review server healthy on port ${PORT}."
  [[ -n "$pid" ]] && log "PID: ${pid}" || log "PID: (unknown)"
  log "Log: ${LOGFILE}"
}

cmd_ensure() {
  if is_healthy; then
    ok "Review server running on port ${PORT}."
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
    echo "Usage: scripts/review-server.sh {start|stop|restart|status|ensure}"
    echo ""
    echo "  start    Start if not running (kills stale processes on port)"
    echo "  stop     Stop the server"
    echo "  restart  Force restart"
    echo "  status   Health check"
    echo "  ensure   Idempotent: start if not running"
    exit 1
    ;;
esac
