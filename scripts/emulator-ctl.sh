#!/usr/bin/env bash
# scripts/emulator-ctl.sh — always-on, CPU-ISOLATED Android emulator lifecycle.
#
# The emulator runs as a sibling process inside fd-dev and used to crash under
# Gradle CPU contention (swiftshader "bad color buffer handle"). This pins it to
# its OWN cores (off the build cores) + gives it memory, launches it DETACHED
# (setsid+nohup) so it survives across agent turns / bg-task reaping, and is
# idempotent: `ensure` REUSES a live emulator instead of rebooting (no churn,
# no contention). Pair with native-connect-test.sh (runs the build on the OTHER
# cores) so the emulator and the build never share a CPU.
#
# Usage: scripts/emulator-ctl.sh {ensure|status|stop|restart|wipe} [avd-name]
#   ensure   boot iff not already booted; reuse otherwise. Waits for readiness.
#   status   print device + boot state (exit 0 booted, 1 not).
#   stop     kill the emulator.
#   restart  stop + ensure (does NOT reset /data — see wipe).
#   wipe     stop + cold boot with -wipe-data → HEAVY RESET of the guest /data
#            partition. The AVD's userdata (config disk.dataPartition) accumulates
#            installs/caches that are baked into the persistent userdata qcow2 and
#            RELOAD on every -read-only boot, so a plain restart does NOT free
#            space — only -wipe-data does. Used by emulator-maintain.sh when
#            /data crosses the low-space threshold. CPU-pinned exactly like a
#            normal boot (no swiftshader/contention regression).
#
# Env: EMU_CORES (default 0-2), EMU_MEMORY_MB (default 4096), AVD (default
#      MobiSSH_Pixel7), EMU_WIPE (default 0; 1 → boot with -wipe-data and drop
#      -read-only so the reset persists to the userdata qcow2).
set -euo pipefail

export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-/opt/android-sdk}"
export ANDROID_AVD_HOME="${ANDROID_AVD_HOME:-$HOME/.android/avd}"
ADB="$ANDROID_SDK_ROOT/platform-tools/adb"
EMU="$ANDROID_SDK_ROOT/emulator/emulator"
AVD="${2:-${AVD:-MobiSSH_Pixel7}}"
EMU_CORES="${EMU_CORES:-0-2}"
EMU_MEMORY_MB="${EMU_MEMORY_MB:-4096}"
EMU_WIPE="${EMU_WIPE:-0}"
LOGDIR="/tmp/mobissh/logs"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/emulator-detached.log"

log() { echo "> $*"; }
err() { echo "! $*" >&2; }

live_device() { "$ADB" devices | awk 'NR>1 && $2=="device"{print $1; exit}'; }

is_booted() {
  local dev="$1"
  [[ -n "$dev" ]] || return 1
  local b
  b="$("$ADB" -s "$dev" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')"
  [[ "$b" == "1" ]]
}

wait_booted() {
  local dev secs=0
  log "waiting for emulator to attach + finish booting (<= 240s)"
  "$ADB" wait-for-device 2>/dev/null || true
  while (( secs < 240 )); do
    dev="$(live_device)"
    if is_booted "$dev"; then
      log "BOOTED: $dev (cores $EMU_CORES, ${EMU_MEMORY_MB}MB)"
      return 0
    fi
    sleep 3; secs=$((secs + 3))
  done
  err "emulator did not boot within 240s — see $LOG"
  return 1
}

clear_stale() {
  # A crashed instance leaves multiinstance/qemu locks + a running-registry that
  # block a fresh boot ("Running multiple emulators with the same AVD").
  rm -f "$ANDROID_AVD_HOME/${AVD}.avd/multiinstance.lock" \
        "$ANDROID_AVD_HOME/${AVD}.avd/hardware-qemu.ini.lock" 2>/dev/null || true
  rm -rf "$ANDROID_AVD_HOME/running" 2>/dev/null || true
}

boot() {
  if ! command -v taskset >/dev/null 2>&1; then
    err "taskset not found (util-linux) — booting WITHOUT cpu pin"
    PIN=()
  else
    PIN=(taskset -c "$EMU_CORES")
  fi
  if pgrep -f GradleDaemon >/dev/null 2>&1; then
    log "killing stray GradleDaemon to free memory before boot"
    pkill -f GradleDaemon || true
  fi
  for d in $("$ADB" devices | grep -oE '^emulator-[0-9]+' || true); do
    log "killing pre-existing $d"
    "$ADB" -s "$d" emu kill 2>/dev/null || true
  done
  clear_stale
  # Base flags shared by every boot. -read-only lets multiple instances share the
  # AVD and keeps writes in a throwaway overlay; a WIPE boot drops it so the fresh
  # (empty) userdata is written back to the persistent qcow2 — otherwise the next
  # -read-only boot would just reload the old, full baseline.
  local flags=(-no-window -no-audio -no-boot-anim -no-snapshot \
    -memory "$EMU_MEMORY_MB" -gpu swiftshader_indirect -accel auto)
  if [[ "$EMU_WIPE" == "1" ]]; then
    log "WIPE boot: -wipe-data (resets guest /data), dropping -read-only so it persists"
    flags+=(-wipe-data)
  else
    flags+=(-read-only)
  fi
  log "booting $AVD detached, pinned to cores $EMU_CORES, ${EMU_MEMORY_MB}MB"
  setsid nohup "${PIN[@]}" "$EMU" -avd "$AVD" "${flags[@]}" >"$LOG" 2>&1 &
  log "launched (pid $!), log: $LOG"
}

cmd="${1:-ensure}"
case "$cmd" in
  ensure)
    dev="$(live_device)"
    if is_booted "$dev"; then
      log "reusing live emulator: $dev (no reboot)"
      exit 0
    fi
    boot
    wait_booted
    ;;
  status)
    dev="$(live_device)"
    if is_booted "$dev"; then echo "booted: $dev"; exit 0; fi
    echo "not booted"; exit 1
    ;;
  stop)
    for d in $("$ADB" devices | grep -oE '^emulator-[0-9]+' || true); do
      log "stopping $d"; "$ADB" -s "$d" emu kill 2>/dev/null || true
    done
    clear_stale
    ;;
  restart)
    "$0" stop "$AVD" || true
    "$0" ensure "$AVD"
    ;;
  wipe)
    log "WIPE requested — stop + cold boot with -wipe-data (heavy /data reset)"
    "$0" stop "$AVD" || true
    clear_stale
    EMU_WIPE=1 boot
    wait_booted
    ;;
  *)
    err "usage: emulator-ctl.sh {ensure|status|stop|restart|wipe} [avd-name]"; exit 2
    ;;
esac
