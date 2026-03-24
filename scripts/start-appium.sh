#!/usr/bin/env bash
# scripts/start-appium.sh — Appium server lifecycle management
#
# Usage:
#   ./scripts/start-appium.sh start     # start (kills existing first)
#   ./scripts/start-appium.sh stop      # stop server
#   ./scripts/start-appium.sh restart   # force restart
#   ./scripts/start-appium.sh status    # health check
#   ./scripts/start-appium.sh ensure    # start if not running or unhealthy
#   ./scripts/start-appium.sh reset     # clear UiAutomator2 state + restart
#
# Environment:
#   APPIUM_PORT — server port (default: 4723)
# Logs:
#   /tmp/appium-server.log  — Appium server stdout/stderr
#   /tmp/appium-mgmt.log    — lifecycle management actions

set -euo pipefail

APPIUM_PORT="${APPIUM_PORT:-4723}"
LOGFILE="/tmp/appium-server.log"
MGMT_LOG="/tmp/appium-mgmt.log"
STATUS_URL="http://localhost:${APPIUM_PORT}/status"

log() { echo "> $*"; echo "$(date '+%H:%M:%S') > $*" >> "$MGMT_LOG"; }
err() { echo "! $*" >&2; echo "$(date '+%H:%M:%S') ! $*" >> "$MGMT_LOG"; }
ok()  { echo "+ $*"; echo "$(date '+%H:%M:%S') + $*" >> "$MGMT_LOG"; }

load_nvm() {
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  if [ -s "$NVM_DIR/nvm.sh" ]; then
    # nvm.sh auto-runs "nvm use default" which may exit non-zero
    # if no default alias is set — temporarily disable errexit
    set +e
    . "$NVM_DIR/nvm.sh"
    nvm use --delete-prefix 20 >/dev/null 2>&1
    local rc=$?
    set -e
    if [ $rc -ne 0 ]; then
      err "nvm use 20 failed. Install with: nvm install 20"
      exit 1
    fi
  else
    err "nvm not found. Run ./scripts/setup-appium.sh first."
    exit 1
  fi
}

load_android_env() {
  export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
  export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"
}

is_healthy() {
  curl -sf "$STATUS_URL" >/dev/null 2>&1
}

find_pid() {
  pgrep -f "appium.*--port ${APPIUM_PORT}" 2>/dev/null | head -1 || echo ""
}

do_status() {
  local pid
  pid=$(find_pid)
  if [ -n "$pid" ] && is_healthy; then
    local version
    version=$(curl -sf "$STATUS_URL" | python3 -c "import sys,json; print(json.load(sys.stdin)['value']['build']['version'])" 2>/dev/null || echo "unknown")
    ok "Appium ${version} running (PID ${pid}) on :${APPIUM_PORT}"
    return 0
  elif [ -n "$pid" ]; then
    err "Appium process exists (PID ${pid}) but not healthy"
    return 1
  else
    log "Appium not running"
    return 1
  fi
}

do_stop() {
  local pid
  pid=$(find_pid)
  if [ -n "$pid" ]; then
    log "Stopping Appium (PID ${pid})..."
    if ! kill "$pid" 2>&1; then
      log "kill $pid failed (process may have already exited)"
    fi
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
      log "Process $pid still alive, sending SIGKILL"
      kill -9 "$pid" 2>&1
    fi
    ok "Appium stopped."
  else
    log "Appium not running."
  fi
}

do_start() {
  do_stop
  load_nvm
  load_android_env
  log "Starting Appium on :${APPIUM_PORT}..."
  local appium_bin
  appium_bin=$(which appium 2>/dev/null || find "$NVM_DIR/versions" -name appium \( -type f -o -type l \) 2>/dev/null | head -1)
  if [ -z "$appium_bin" ]; then
    err "appium binary not found. Install with: npm install -g appium"
    return 1
  fi
  nohup "$appium_bin" --port "$APPIUM_PORT" --relaxed-security > "$LOGFILE" 2>&1 &
  local pid=$!
  local attempts=0
  while [ $attempts -lt 15 ]; do
    if is_healthy; then
      ok "Appium started (PID ${pid}, port ${APPIUM_PORT})"
      ok "Log: ${LOGFILE}"
      return 0
    fi
    sleep 1
    attempts=$((attempts + 1))
  done
  err "Appium failed to become healthy within 15s. Check ${LOGFILE}"
  tail -10 "$LOGFILE"
  return 1
}

do_restart() {
  do_start
}

do_ensure() {
  if is_healthy; then
    do_status
  else
    do_start
  fi
}

do_reset() {
  log "Clearing UiAutomator2 state on device..."
  if ! adb shell pm clear io.appium.uiautomator2.server 2>&1; then
    log "pm clear uiautomator2.server failed (app may not be installed)"
  fi
  if ! adb shell pm clear io.appium.settings 2>&1; then
    log "pm clear io.appium.settings failed (app may not be installed)"
  fi
  log "Restarting Appium..."
  do_start
}

case "${1:-ensure}" in
  start)   do_start ;;
  stop)    do_stop ;;
  restart) do_restart ;;
  status)  do_status ;;
  ensure)  do_ensure ;;
  reset)   do_reset ;;
  *)
    err "Usage: $0 {start|stop|restart|status|ensure|reset}"
    exit 1
    ;;
esac
