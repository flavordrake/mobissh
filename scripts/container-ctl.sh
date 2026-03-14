#!/usr/bin/env bash
# scripts/container-ctl.sh — Production container lifecycle for acceptance testing
#
# Manages the Docker production container (mobissh-prod) with build verification,
# health checks, and code-currency validation.
#
# Usage:
#   scripts/container-ctl.sh start       # build + start (or restart if stale)
#   scripts/container-ctl.sh stop        # stop container
#   scripts/container-ctl.sh restart     # force rebuild + restart
#   scripts/container-ctl.sh status      # health + version check
#   scripts/container-ctl.sh ensure      # idempotent: rebuild only if stale

set -euo pipefail
cd "$(dirname "$0")/.."

MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"
LOGFILE="${MOBISSH_LOGDIR}/container-ctl.log"
exec > >(tee -a "$LOGFILE") 2>&1

COMPOSE_FILE="docker-compose.prod.yml"
CONTAINER="mobissh-prod"
HEALTH_TIMEOUT=30

log() { echo "> $*"; }
err() { echo "! $*" >&2; }
ok()  { echo "+ $*"; }

head_hash() {
  git rev-parse --short HEAD 2>/dev/null || echo "unknown"
}

# Check if the container is running
is_running() {
  docker ps --filter "name=${CONTAINER}" --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER}$"
}

# Read the baked git hash from inside the container
container_version() {
  docker exec "$CONTAINER" cat /app/.git-hash 2>/dev/null | tr -d '[:space:]' || echo ""
}

# Wait for the server inside the container to respond
wait_healthy() {
  local elapsed=0
  while (( elapsed < HEALTH_TIMEOUT )); do
    # Use node inside the container (curl/wget not installed in slim image)
    if docker exec "$CONTAINER" node -e "
      const h=require('http');
      const r=h.get('http://localhost:8081/',res=>{
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

# Check if the container code matches HEAD
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

  # SW cache name: content hash of cached files, not a monotonic counter.
  # The browser re-triggers SW update when sw.js changes byte-for-byte.
  # Network-first + no-store means the cache is offline-fallback only —
  # bumping on every rebuild was noise (#146).
  local sw_file="public/sw.js"
  if [[ -f "$sw_file" ]]; then
    local content_hash
    content_hash=$(find public/ -type f -not -name 'sw.js' -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-8)
    local current_name
    current_name=$(grep -oP "mobissh-[a-z0-9]+" "$sw_file" | head -1)
    local new_name="mobissh-${content_hash}"
    if [[ "$current_name" != "$new_name" ]]; then
      sed -i "s/${current_name}/${new_name}/" "$sw_file"
      log "SW cache: ${current_name} → ${new_name}"
    else
      log "SW cache: ${new_name} (unchanged)"
    fi
  fi

  log "Building ${CONTAINER} at ${hash}..."
  GIT_HASH="$hash" docker compose -f "$COMPOSE_FILE" build --build-arg "GIT_HASH=${hash}" 2>&1
  ok "Image built."
}

cmd_up() {
  log "Starting ${CONTAINER}..."
  # Ensure shared Docker network exists (external: true in compose requires pre-creation)
  docker network create mobissh 2>/dev/null || true
  docker compose -f "$COMPOSE_FILE" up -d 2>&1

  if wait_healthy; then
    local serving
    serving=$(container_version)
    ok "Container healthy (version ${serving})."
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

  local serving
  serving=$(container_version)

  if [[ "$serving" == "$head" ]]; then
    ok "Code current: ${serving} (matches HEAD)."
  else
    err "STALE: serving ${serving:-empty}, HEAD is ${head}. Run: scripts/container-ctl.sh restart"
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

cmd_push() {
  if ! is_running; then
    err "Container ${CONTAINER} not running. Use 'restart' for a full rebuild."
    return 1
  fi

  log "Compiling TypeScript..."
  npx tsc 2>&1

  log "Pushing public/ and server/ into ${CONTAINER}..."
  docker cp public/. "${CONTAINER}:/app/public/"
  docker cp server/. "${CONTAINER}:/app/server/"

  ok "Files pushed. Refresh the browser (no container restart needed)."
}

case "${1:-}" in
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  restart) cmd_restart ;;
  status)  cmd_status ;;
  ensure)  cmd_ensure ;;
  push)    cmd_push ;;
  *)
    echo "Usage: scripts/container-ctl.sh {start|stop|restart|status|ensure|push}"
    echo ""
    echo "  start    Build + start (rebuild if stale)"
    echo "  stop     Stop container"
    echo "  restart  Force rebuild + restart"
    echo "  status   Health + version check"
    echo "  ensure   Idempotent: rebuild only if code is stale"
    echo "  push     Hot-push: compile TS + copy files into running container (fast)"
    exit 1
    ;;
esac
