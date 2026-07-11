#!/usr/bin/env bash
# scripts/ci-reap.sh — belt-and-braces sweeper for orphaned test infrastructure (#1049).
#
# Operator directive (agent-hub msg 64, 2026-07-11): agent-*-test-sshd-1 fixtures
# aged 3-12 days plus a 5-day idle emulator swap-thrashed the PVE host (load 190).
# Primary teardown is the EXIT traps in the spawning scripts (see
# scripts/lib/testsshd-fixture.sh for the mechanism map); this sweep catches what
# traps cannot: kill -9, worktree deleted mid-run, and test-sshd-up.sh fixtures
# that intentionally outlive one script call (multi-test agent runs).
#
# Actions per sweep:
#   1. REMOVE agent-*-test-sshd-1 containers older than CI_REAP_MAX_AGE_HOURS
#      (default 6). Age = the container's docker Created timestamp. The age
#      guard is what protects ACTIVE agents' fixtures — anything younger than
#      the threshold is never touched.
#   2. STOP (never remove) the mobissh-emulator container when idle longer than
#      CI_REAP_EMU_IDLE_HOURS (default 12). Idle = age of the last-used marker
#      (${MOBISSH_TMPDIR}/emulator-last-used) that emu-container-ctl.sh touches
#      on every ensure/up/restart/wipe. A missing marker is touched NOW (starts
#      the clock) — never an instant stop. `emu-container-ctl.sh ensure` re-boots
#      a stopped emulator on demand (~2min).
#   3. NEVER touches fd-dev, mobissh-prod, mobissh-feedback, or the canonical
#      mobissh-test-sshd-1 fixture: strict ^agent-*-test-sshd-1$ name pattern
#      PLUS an explicit protected-name list.
#
# Wire-in: called opportunistically (non-fatal) from emulator-ctl.sh ensure and
# emu-container-ctl.sh ensure. `install-cron` adds an hourly entry when a cron
# daemon exists — fd-dev has none today, so the ensure wire-in is the active
# cadence.
#
# Usage: scripts/ci-reap.sh [run|install-cron]
# Env:
#   CI_REAP_MAX_AGE_HOURS   fixture age threshold in hours, fractional ok (default 6)
#   CI_REAP_EMU_IDLE_HOURS  emulator idle threshold in hours, fractional ok (default 12)
#   CI_REAP_NAME_PREFIX     fixture container-name prefix to consider (default
#                           "agent-"; live verification scopes this to its own
#                           throwaway projects so parallel agents are untouched)
#   CI_REAP_DRY_RUN         1 = log intended actions without executing (default 0)
set -euo pipefail

MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"
LOGFILE="${MOBISSH_LOGDIR}/ci-reap.log"
exec > >(tee -a "$LOGFILE") 2>&1

CI_REAP_MAX_AGE_HOURS="${CI_REAP_MAX_AGE_HOURS:-6}"
CI_REAP_EMU_IDLE_HOURS="${CI_REAP_EMU_IDLE_HOURS:-12}"
CI_REAP_NAME_PREFIX="${CI_REAP_NAME_PREFIX:-agent-}"
CI_REAP_DRY_RUN="${CI_REAP_DRY_RUN:-0}"
EMU_CONTAINER="mobissh-emulator"
EMU_MARKER="${MOBISSH_TMPDIR}/emulator-last-used"

log() { echo "> [$(date +%Y%m%dT%H%M%S%z)] ci-reap: $*"; }
err() { echo "! [$(date +%Y%m%dT%H%M%S%z)] ci-reap: $*" >&2; }

hours_to_secs() { awk -v h="$1" 'BEGIN{printf "%.0f", h*3600}'; }

is_protected() {
  local name="$1"
  case "$name" in
    fd-dev|mobissh-prod|mobissh-feedback|mobissh-test-sshd-1|"$EMU_CONTAINER") return 0 ;;
  esac
  # This dev container itself (hostname is its container id/name).
  [[ "$name" == "$(hostname)" ]]
}

reap_fixtures() {
  local max_age_s now names name created_s age_s
  max_age_s="$(hours_to_secs "$CI_REAP_MAX_AGE_HOURS")"
  now="$(date +%s)"
  names="$(docker ps -a --format '{{.Names}}')"
  local matched=0
  for name in $names; do
    case "$name" in
      "${CI_REAP_NAME_PREFIX}"*-test-sshd-1) ;;
      *) continue ;;
    esac
    if is_protected "$name"; then
      log "SKIP protected: $name"
      continue
    fi
    matched=$((matched + 1))
    # Container may vanish between `docker ps` and `inspect` (trap teardown
    # racing the sweep) — skip instead of aborting the whole sweep.
    if ! created_s="$(date -d "$(docker inspect -f '{{.Created}}' "$name")" +%s)"; then
      log "SKIP $name (inspect failed — likely torn down concurrently)"
      continue
    fi
    age_s=$(( now - created_s ))
    if (( age_s > max_age_s )); then
      if [[ "$CI_REAP_DRY_RUN" == "1" ]]; then
        log "DRY RUN: would remove $name (age ${age_s}s > ${max_age_s}s)"
      else
        log "removing orphaned fixture $name (age ${age_s}s > ${max_age_s}s)"
        if ! docker rm -f "$name"; then
          err "failed to remove $name"
        fi
      fi
    else
      log "keeping $name (age ${age_s}s <= ${max_age_s}s)"
    fi
  done
  log "fixture sweep done (${matched} candidate(s), prefix '${CI_REAP_NAME_PREFIX}', threshold ${CI_REAP_MAX_AGE_HOURS}h)"
}

reap_emulator() {
  local idle_max_s now marker_s idle_s
  if ! docker ps --format '{{.Names}}' | grep -qx "$EMU_CONTAINER"; then
    log "emulator: $EMU_CONTAINER not running — nothing to do"
    return 0
  fi
  if [[ ! -f "$EMU_MARKER" ]]; then
    # No marker (fresh fd-dev, or pre-#1049): start the idle clock now instead
    # of guessing — never an instant stop.
    date +%Y%m%dT%H%M%S%z > "$EMU_MARKER"
    log "emulator: no last-used marker — created $EMU_MARKER (idle clock starts now)"
    return 0
  fi
  idle_max_s="$(hours_to_secs "$CI_REAP_EMU_IDLE_HOURS")"
  now="$(date +%s)"
  marker_s="$(stat -c %Y "$EMU_MARKER")"
  idle_s=$(( now - marker_s ))
  if (( idle_s > idle_max_s )); then
    if [[ "$CI_REAP_DRY_RUN" == "1" ]]; then
      log "DRY RUN: would stop $EMU_CONTAINER (idle ${idle_s}s > ${idle_max_s}s)"
    else
      log "stopping idle $EMU_CONTAINER (idle ${idle_s}s > ${idle_max_s}s; ensure re-boots on demand)"
      if ! docker stop "$EMU_CONTAINER"; then
        err "failed to stop $EMU_CONTAINER"
      fi
    fi
  else
    log "emulator: active (idle ${idle_s}s <= ${idle_max_s}s)"
  fi
}

cmd_run() {
  reap_fixtures
  reap_emulator
}

cmd_install_cron() {
  if ! command -v crontab >/dev/null 2>&1; then
    err "no crontab binary on this host (fd-dev runs no cron daemon) — install-cron unavailable"
    err "active cadence is the ci-reap wire-in from emulator-ctl.sh / emu-container-ctl.sh ensure"
    return 1
  fi
  # Cron entry must reference the MAIN repo, not a deletable worktree.
  # shellcheck source=lib/repo-guard.sh
  source "$(dirname "$0")/lib/repo-guard.sh"
  local current=""
  if out="$(crontab -l 2>/dev/null)"; then current="$out"; fi
  # grep exception: zero remaining entries is a valid state.
  strip_ci_reap() { grep -v 'ci-reap' || true; }
  # The redirect inside the CRON LINE stops cron from mailing every sweep; the
  # script already tees its own output to $LOGFILE.
  { printf '%s\n' "$current" | strip_ci_reap
    printf '23 * * * * %s/scripts/ci-reap.sh run >/dev/null 2>&1\n' "$REPO_ROOT"
  } | crontab -
  log "installed hourly cron entry: 23 * * * * ${REPO_ROOT}/scripts/ci-reap.sh run"
}

case "${1:-run}" in
  run)          cmd_run ;;
  install-cron) cmd_install_cron ;;
  *)
    echo "Usage: scripts/ci-reap.sh [run|install-cron]"
    exit 2
    ;;
esac
