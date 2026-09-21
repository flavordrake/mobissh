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

# #1115 fail-closed upload auth: compose reads MOBISSH_FEEDBACK_KEY from our
# environment; source it from the same file APK builds bake it from so client
# and server always agree. Unset key ⇒ the server 503s all uploads (by design).
FEEDBACK_ENV="${HOME}/.mobissh/feedback.env"
if [ -f "$FEEDBACK_ENV" ]; then
  # shellcheck disable=SC1090
  . "$FEEDBACK_ENV"
  export MOBISSH_FEEDBACK_KEY="${FEEDBACK_KEY:-}"
fi

log() { echo "> $*"; }
err() { echo "! $*" >&2; }
ok()  { echo "+ $*"; }

DEPLOY_LOG="${MOBISSH_TMPDIR}/deploy-changelog.md"

# Show what changed since last deploy and what's in flight
show_changelog() {
  local old_hash="$1"
  local new_hash="$2"

  {
    echo "## Deploy: ${old_hash:-initial} → ${new_hash}"
    echo "$(date '+%Y-%m-%d %H:%M:%S')"
    echo ""

    if [[ -n "$old_hash" && "$old_hash" != "$new_hash" ]]; then
      echo "### What's new"
      git log --oneline "${old_hash}..${new_hash}" 2>/dev/null || echo "(unable to diff)"
      echo ""
    fi

    local in_flight
    in_flight=$(git branch -r --list 'origin/bot/*' 2>/dev/null | sed 's|origin/||')
    if [[ -n "$in_flight" ]]; then
      echo "### In flight (not yet merged)"
      echo "$in_flight"
    else
      echo "### In flight: none"
    fi
    echo ""
  } | tee "$DEPLOY_LOG"
}

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

  # Pre-build static check — catches JS errors (use-before-define, etc.) BEFORE
  # baking a broken image. Set SKIP_GATE=1 to bypass in emergencies.
  # #1205: the tsc step and the src/ + public/app.js lint targets went with the
  # PWA; what the image serves now is server/ plus a handful of static files.
  # The service-worker cache-hash rewrite went with public/sw.js.
  if [[ "${SKIP_GATE:-0}" != "1" ]]; then
    log "Pre-build gate: eslint..."
    if ! npx eslint server/ server-feedback/ public/native-time.js public/native-feedback.js 2>&1; then
      err "eslint failed — aborting build. Set SKIP_GATE=1 to override."
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

# #712 — verify the persistent native-dist bind is actually mounted after a
# (re)deploy. A container recreated WITHOUT the docker-compose native-dist mount
# (e.g. a deploy from a checkout lacking #700) serves no APK/install page → the
# download URL 404s. Surface it LOUDLY here instead of discovering it via a 404.
# Reads /version's nativeDist field (added in #712). Returns non-zero on MISSING.
check_native_dist() {
  local body
  body=$(curl -fsS "http://${CONTAINER}:8081/version" 2>/dev/null || true)
  case "$body" in
    *'"nativeDist":"mounted"'*)
      ok "native-dist bind mounted + published (APK/install page served)." ;;
    *'"nativeDist":"EMPTY"'*)
      err "native-dist is mounted but EMPTY — no APK published yet. Run scripts/native-release-apk.sh." ;;
    *'"nativeDist":"MISSING"'*)
      err "!!! native-dist NOT mounted — the APK + install page WILL 404."
      err "    The container was recreated without the docker-compose native-dist bind (#700/#712)."
      err "    Always deploy from the container workspace: scripts/container-ctl.sh restart"
      return 1 ;;
    *)
      log "native-dist status unknown (/version did not report it — older image?)." ;;
  esac
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
    show_changelog "${PREV_VERSION:-}" "$serving"
    check_native_dist || true
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

  PREV_VERSION=""
  if is_running; then
    PREV_VERSION=$(container_version)
    log "Container running but stale (serving ${PREV_VERSION}, HEAD is $(head_hash)). Rebuilding..."
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

  log "Pushing public/ and server/ into ${CONTAINER}..."
  docker cp public/. "${CONTAINER}:/app/public/"
  docker cp server/. "${CONTAINER}:/app/server/"

  ok "Files pushed. Refresh the browser (no container restart needed)."
  show_changelog "$(container_version)" "$(head_hash) (hot-push)"
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
