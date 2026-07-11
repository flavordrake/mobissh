#!/usr/bin/env bash
# scripts/emu-container-ctl.sh — lifecycle for the DEDICATED emulator container.
#
# The Android emulator now runs in its OWN sibling container (mobissh-emulator)
# instead of as a process inside fd-dev. This script manages that CONTAINER via
# docker compose and waits for the guest to finish booting. When swiftshader
# crashes, recovery is `emu-container-ctl.sh restart` — it does NOT touch fd-dev,
# so the coding session (and any accumulated zombie reaping) is unaffected.
#
# Usage: scripts/emu-container-ctl.sh {ensure|restart|wipe|status|logs}
#   ensure   build (if needed) + start; reuse a booted container. Waits for boot.
#   restart  recreate the container (fresh -read-only overlay = clean /data) + wait.
#   wipe     `down` + `up` full recreate (belt-and-suspenders clean /data) + wait.
#   status   print container + guest boot state (exit 0 booted, 1 not).
#   logs     tail the emulator container log.
#
# IDLE-STOP POLICY (#1049, operator directive 2026-07-11): the emulator is no
# longer always-on. A 5-day idle mobissh-emulator (2.8GB) swap-thrashed the PVE
# host, so scripts/ci-reap.sh STOPS the container after CI_REAP_EMU_IDLE_HOURS
# (12h) without use. Every ensure/up/restart/wipe touches the last-used marker
# (${MOBISSH_TMPDIR}/emulator-last-used); `ensure` re-boots a stopped emulator
# on demand (~2min cost) — callers already go through ensure, so idle-stop is
# transparent apart from that boot wait.
#
# Env: EMU_BOOT_TIMEOUT (default 300s), EMU_GPU / EMU_MEMORY_MB / EMU_CORES pass
#      through to the container (see docker-compose.emulator.yml).
set -euo pipefail
cd "$(dirname "$0")/.."

MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"
LOGFILE="${MOBISSH_LOGDIR}/emu-container-ctl.log"
exec > >(tee -a "$LOGFILE") 2>&1

COMPOSE_FILE="docker-compose.emulator.yml"
CONTAINER="mobissh-emulator"
EMU_BOOT_TIMEOUT="${EMU_BOOT_TIMEOUT:-300}"
EMU_MARKER="${MOBISSH_TMPDIR}/emulator-last-used"

log() { echo "> [$(date +%Y%m%dT%H%M%S%z)] $*"; }
err() { echo "! [$(date +%Y%m%dT%H%M%S%z)] $*" >&2; }
ok()  { echo "+ [$(date +%Y%m%dT%H%M%S%z)] $*"; }

# Last-used marker read by scripts/ci-reap.sh for the idle-stop policy (#1049).
touch_last_used() {
  date +%Y%m%dT%H%M%S%z > "$EMU_MARKER"
}

# Opportunistic orphan sweep (#1049) — cheap; the marker is touched FIRST so
# this emulator reads as active. Non-fatal: a reap failure must not block ensure.
opportunistic_reap() {
  if ! scripts/ci-reap.sh run; then
    err "ci-reap sweep failed (non-fatal)"
  fi
}

is_running() {
  docker ps --filter "name=${CONTAINER}" --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER}$"
}

# Boot state read from INSIDE the container (independent of any remote-adb config
# on the caller side).
guest_booted() {
  local b
  b="$(docker exec "$CONTAINER" adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
  [[ "$b" == "1" ]]
}

ensure_network() {
  # external: true compose network must pre-exist.
  docker network create mobissh 2>/dev/null || true
}

wait_boot() {
  local s=0
  log "waiting for guest sys.boot_completed (<= ${EMU_BOOT_TIMEOUT}s)"
  while (( s < EMU_BOOT_TIMEOUT )); do
    if ! is_running; then
      err "container ${CONTAINER} exited during boot — see: emu-container-ctl.sh logs"
      return 1
    fi
    if guest_booted; then
      ok "guest BOOTED (sys.boot_completed=1)"
      docker exec "$CONTAINER" adb devices || true
      return 0
    fi
    sleep 5; s=$((s + 5))
  done
  err "guest did not boot within ${EMU_BOOT_TIMEOUT}s — see: emu-container-ctl.sh logs"
  return 1
}

cmd_up() {
  ensure_network
  touch_last_used
  log "docker compose up -d (${CONTAINER})"
  docker compose -f "$COMPOSE_FILE" up -d --build
  wait_boot
}

cmd_ensure() {
  touch_last_used
  opportunistic_reap
  if is_running && guest_booted; then
    ok "${CONTAINER} already up + booted."
    return 0
  fi
  if is_running; then
    log "${CONTAINER} running but guest not booted yet — waiting."
    wait_boot
    return $?
  fi
  cmd_up
}

cmd_restart() {
  ensure_network
  touch_last_used
  log "recreating ${CONTAINER} (fresh -read-only overlay = clean /data)"
  docker compose -f "$COMPOSE_FILE" up -d --build --force-recreate
  wait_boot
}

cmd_wipe() {
  ensure_network
  touch_last_used
  log "wipe: full down + up recreate of ${CONTAINER}"
  docker compose -f "$COMPOSE_FILE" down || true
  docker compose -f "$COMPOSE_FILE" up -d --build --force-recreate
  wait_boot
}

cmd_status() {
  if ! is_running; then
    err "${CONTAINER} is NOT running."
    return 1
  fi
  log "container: $(docker ps --filter "name=${CONTAINER}" --format '{{.Status}}')"
  if guest_booted; then
    ok "guest booted."
    docker exec "$CONTAINER" adb devices || true
    return 0
  fi
  err "guest NOT booted yet."
  return 1
}

cmd_logs() {
  docker logs --tail "${TAIL:-80}" "$CONTAINER"
}

case "${1:-}" in
  ensure)  cmd_ensure ;;
  restart) cmd_restart ;;
  wipe)    cmd_wipe ;;
  status)  cmd_status ;;
  logs)    cmd_logs ;;
  *)
    echo "Usage: scripts/emu-container-ctl.sh {ensure|restart|wipe|status|logs}"
    exit 1
    ;;
esac
