#!/usr/bin/env bash
# scripts/feedback-ctl.sh — Feedback service container lifecycle (#997)
#
# Manages the dedicated bug-report/telemetry container (mobissh-feedback)
# mirroring container-ctl.sh conventions: idempotent network create, build
# verification, health check via /healthz, code-currency check.
#
# Usage:
#   scripts/feedback-ctl.sh start       # build + start (or restart if stale)
#   scripts/feedback-ctl.sh stop        # stop container
#   scripts/feedback-ctl.sh restart     # force rebuild + restart
#   scripts/feedback-ctl.sh status      # health + version check
#   scripts/feedback-ctl.sh ensure      # idempotent: rebuild only if stale

set -euo pipefail
cd "$(dirname "$0")/.."

MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"
LOGFILE="${MOBISSH_LOGDIR}/feedback-ctl.log"
exec > >(tee -a "$LOGFILE") 2>&1

COMPOSE_FILE="docker-compose.feedback.yml"
CONTAINER="mobissh-feedback"
HEALTH_TIMEOUT=30

# #1115 fail-closed upload auth: same key file the APK builds bake the client
# key from (~/.mobissh/feedback.env) so both front doors accept the same key.
FEEDBACK_ENV="${HOME}/.mobissh/feedback.env"
if [ -f "$FEEDBACK_ENV" ]; then
  # shellcheck disable=SC1090
  . "$FEEDBACK_ENV"
  export MOBISSH_FEEDBACK_KEY="${FEEDBACK_KEY:-}"
fi

log() { echo "> $*"; }
err() { echo "! $*" >&2; }
ok()  { echo "+ $*"; }

head_hash() {
  git rev-parse --short HEAD 2>/dev/null || echo "unknown"
}

is_running() {
  docker ps --filter "name=${CONTAINER}" --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER}$"
}

container_version() {
  docker exec "$CONTAINER" cat /app/.git-hash 2>/dev/null | tr -d '[:space:]' || echo ""
}

# Wait for /healthz inside the container (curl/wget not in slim image)
wait_healthy() {
  local elapsed=0
  while (( elapsed < HEALTH_TIMEOUT )); do
    if docker exec "$CONTAINER" node -e "
      const h=require('http');
      const r=h.get('http://localhost:8082/healthz',res=>{
        process.exit(res.statusCode===200?0:1);
      });
      r.on('error',()=>process.exit(1));
      r.setTimeout(2000,()=>{r.destroy();process.exit(1)});
    " 2>/dev/null; then
      return 0
    fi
    sleep 1
    (( elapsed++ ))
  done
  return 1
}

is_current() {
  local serving head
  serving=$(container_version)
  head=$(head_hash)
  [[ -n "$serving" && "$serving" == "$head" ]]
}

cmd_stop() {
  if ! is_running; then
    log "Container ${CONTAINER} not running."
    return 0
  fi
  log "Stopping ${CONTAINER}..."
  docker compose -f "$COMPOSE_FILE" stop
  ok "Container stopped."
}

cmd_build() {
  local hash
  hash=$(head_hash)

  # Pre-build gate: plain syntax check (the service has no TS and no deps).
  if [[ "${SKIP_GATE:-0}" != "1" ]]; then
    log "Pre-build gate: node --check..."
    if ! node --check server-feedback/index.js; then
      err "node --check server-feedback/index.js failed — aborting build."
      exit 1
    fi
    if ! node --check server/feedback-store.js; then
      err "node --check server/feedback-store.js failed — aborting build."
      exit 1
    fi
    ok "Pre-build gate passed."
  else
    log "Pre-build gate: SKIPPED (SKIP_GATE=1)"
  fi

  log "Building ${CONTAINER} at ${hash}..."
  GIT_HASH="$hash" docker compose -f "$COMPOSE_FILE" build --build-arg "GIT_HASH=${hash}" 2>&1
  ok "Image built."
}

cmd_up() {
  log "Starting ${CONTAINER}..."
  # Ensure shared Docker network exists (external: true requires pre-creation)
  docker network create mobissh 2>/dev/null || true
  docker compose -f "$COMPOSE_FILE" up -d 2>&1

  if wait_healthy; then
    ok "Container healthy (version $(container_version))."
  else
    err "Container failed to become healthy within ${HEALTH_TIMEOUT}s."
    err "Logs:"
    docker logs --tail 20 "$CONTAINER"
    return 1
  fi
}

cmd_start() {
  if is_running && is_current; then
    ok "Container already running at HEAD ($(head_hash))."
    return 0
  fi
  if is_running; then
    log "Container running but stale (serving $(container_version), HEAD is $(head_hash)). Rebuilding..."
  fi
  cmd_build
  cmd_up
}

cmd_restart() {
  cmd_build
  cmd_up
}

cmd_status() {
  local head
  head=$(head_hash)

  if ! is_running; then
    err "Container ${CONTAINER} is NOT running."
    return 1
  fi

  local uptime
  uptime=$(docker ps --filter "name=${CONTAINER}" --format '{{.Status}}')
  log "Status: ${uptime}"

  if wait_healthy; then
    ok "Healthz OK."
  else
    err "Healthz FAILED."
    return 1
  fi

  local serving
  serving=$(container_version)
  if [[ "$serving" == "$head" ]]; then
    ok "Code current: ${serving} (matches HEAD)."
  else
    err "STALE: serving ${serving:-empty}, HEAD is ${head}. Run: scripts/feedback-ctl.sh restart"
    return 1
  fi
}

cmd_ensure() {
  if is_running && is_current; then
    ok "Container healthy at HEAD ($(head_hash))."
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
    echo "Usage: scripts/feedback-ctl.sh {start|stop|restart|status|ensure}"
    echo ""
    echo "  start    Build + start (rebuild if stale)"
    echo "  stop     Stop container"
    echo "  restart  Force rebuild + restart"
    echo "  status   Health + version check"
    echo "  ensure   Idempotent: rebuild only if code is stale"
    exit 1
    ;;
esac
