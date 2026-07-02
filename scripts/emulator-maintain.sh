#!/usr/bin/env bash
# scripts/emulator-maintain.sh — keep the always-on emulator's /data healthy so
# integration installs never hit INSTALL_FAILED_INSUFFICIENT_STORAGE.
#
# WHY: the AVD's userdata partition (6 GB, config.ini disk.dataPartition) fills
# up with app installs + caches across a long-lived, REUSED emulator session.
# Because boot uses -read-only + -no-snapshot, that baseline is baked into the
# persistent userdata-qemu.img.qcow2 and RELOADS on every cold boot — a plain
# restart does NOT free it. Only a -wipe-data cold boot (emulator-ctl.sh wipe)
# truly resets /data (observed: 88% used → 14% used, ~5 GB free).
#
# STRATEGY (idempotent, cheap-first — never wipe a healthy emulator):
#   1. light clean — uninstall the app + its .test package, pm trim-caches
#   2. measure — df /data vs a free-space threshold
#   3. rotate (heavy) — ONLY when still below threshold (or --rotate/rotate):
#      emulator-ctl.sh wipe → fresh /data, CPU-pinned exactly like a normal boot.
#
# Usage: scripts/emulator-maintain.sh {ensure-healthy|check|clean|rotate} [--rotate]
#   ensure-healthy  (default) ensure booted → clean → rotate iff still low.
#                   --rotate forces the heavy reset regardless of free space.
#   check           report df /data; exit 0 healthy, 3 below threshold.
#   clean           light clean (uninstall + trim), then check.
#   rotate          force a -wipe-data reset (heavy), then check.
#
# Env: EMU_MIN_FREE_MB (default 1536) — rotate when free MB drops below this.
#      APP_ID          (default com.flavordrake.mobissh) — its .test sibling is
#                      derived and cleaned too.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"
LOGFILE="${MOBISSH_LOGDIR}/emulator-maintain.log"
exec > >(tee -a "$LOGFILE") 2>&1

export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-/opt/android-sdk}"
ADB="$ANDROID_SDK_ROOT/platform-tools/adb"
EMU_MIN_FREE_MB="${EMU_MIN_FREE_MB:-1536}"
APP_ID="${APP_ID:-com.flavordrake.mobissh}"
TEST_APP_ID="${APP_ID}.test"

log() { echo "> $(date +%Y%m%dT%H%M%S%z) maintain: $*"; }
err() { echo "! maintain: $*" >&2; }

device() { "$ADB" devices | awk 'NR>1 && $2=="device" {print $1; exit}'; }

# Free MB on the guest /data partition. Echoes an integer; empty on failure.
free_mb() {
  local dev="$1" line avail_kb
  # df output: Filesystem 1K-blocks Used Available Use% Mounted; Available = col 4.
  line="$("$ADB" -s "$dev" shell df /data 2>/dev/null | awk 'NR==2{print}' | tr -d '\r')"
  avail_kb="$(echo "$line" | awk '{print $4}')"
  [[ "$avail_kb" =~ ^[0-9]+$ ]] || return 1
  echo $(( avail_kb / 1024 ))
}

report_df() {
  local dev="$1"
  log "df /data on $dev:"
  "$ADB" -s "$dev" shell df /data 2>/dev/null | tr -d '\r' || true
}

# Exit 0 if free space >= threshold, 3 if below. Prints the numbers.
check() {
  local dev fm
  dev="$(device)"
  if [[ -z "$dev" ]]; then err "no online adb device"; return 2; fi
  report_df "$dev"
  fm="$(free_mb "$dev")" || { err "could not read df /data"; return 2; }
  if (( fm < EMU_MIN_FREE_MB )); then
    log "LOW: ${fm}MB free < ${EMU_MIN_FREE_MB}MB threshold"
    return 3
  fi
  log "OK: ${fm}MB free >= ${EMU_MIN_FREE_MB}MB threshold"
  return 0
}

# Light clean: uninstall the app + its instrumentation package, trim caches.
clean() {
  local dev
  dev="$(device)"
  if [[ -z "$dev" ]]; then err "no online adb device"; return 2; fi
  log "light clean: uninstall $APP_ID / $TEST_APP_ID + pm trim-caches"
  "$ADB" -s "$dev" uninstall "$APP_ID" 2>/dev/null || log "  (app not installed / uninstall no-op)"
  "$ADB" -s "$dev" uninstall "$TEST_APP_ID" 2>/dev/null || log "  (.test not installed / uninstall no-op)"
  # Trim every cache down to 0 free-space target (max long → drop all cached data).
  "$ADB" -s "$dev" shell pm trim-caches 9223372036854775807 2>/dev/null || log "  (trim-caches unavailable)"
}

# Heavy reset: cold boot with -wipe-data via the lifecycle script (keeps CPU pin).
rotate() {
  log "ROTATE: heavy /data reset via emulator-ctl.sh wipe"
  if ! "${REPO_ROOT}/scripts/emulator-ctl.sh" wipe; then
    err "emulator-ctl.sh wipe failed — see /tmp/mobissh/logs/emulator-detached.log"
    return 2
  fi
}

cmd="${1:-ensure-healthy}"
FORCE_ROTATE=0
for a in "$@"; do [[ "$a" == "--rotate" ]] && FORCE_ROTATE=1; done

case "$cmd" in
  check)
    check
    ;;
  clean)
    clean
    check
    ;;
  rotate)
    rotate
    check
    ;;
  ensure-healthy)
    # Make sure something is booted first (boots-or-reuses, CPU-pinned).
    if ! "${REPO_ROOT}/scripts/emulator-ctl.sh" ensure; then
      err "emulator-ctl.sh ensure failed"; exit 2
    fi
    if (( FORCE_ROTATE == 1 )); then
      log "--rotate: forcing heavy reset"
      rotate
      check
      exit $?
    fi
    # Cheap path first: light clean, then measure.
    clean
    if check; then
      log "healthy after light clean — no rotate needed"
      exit 0
    fi
    log "still low after light clean — escalating to rotate"
    rotate
    if check; then
      log "healthy after rotate"
      exit 0
    fi
    err "STILL low after wipe — /data threshold unreachable (base image too big?)"
    exit 3
    ;;
  *)
    err "usage: emulator-maintain.sh {ensure-healthy|check|clean|rotate} [--rotate]"
    exit 2
    ;;
esac
