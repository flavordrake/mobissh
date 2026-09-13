#!/usr/bin/env bash
# scripts/with-fleet-emulator.sh — run a command while holding an EXCLUSIVE lease
# on the SHARED fleet Android emulator (CT113 `android-emulator`), then hand the
# leased device's adb endpoint to the command via EMU_ADBD_ENDPOINT + EMU_ENSURE=0.
#
# WHY (#1098): the emulator graduated out of fd-dev. The old `mobissh-emulator`
# container is RETIRED and `emu-container-ctl.sh ensure` hard-refuses. The fleet
# device is ON-DEMAND: it is idle-stopped and only boots when a lease is acquired
# (~135s cold), so a bare `adb connect` is refused — there is nothing listening
# until you hold the lease. Booting a LOCAL avd instead is wrong: it re-grabs the
# pve iGPU DRM master and fights CT113 (see emu-container-ctl.sh).
#
# The lease is `ssh + flock` against the emulator LXC, published on the fleet bus
# as host@android-emulator's `device-lease` offer. It exists so mobissh and
# scrapdaw never drive the single device at once (installs / global-settings
# writes / reboots would collide). Exclusivity is the point — do not bypass it.
#
# Usage:
#   scripts/with-fleet-emulator.sh -- scripts/native-integration-suite.sh
#   scripts/with-fleet-emulator.sh -- scripts/native-fast-gate.sh --with-integration
#
# Env:
#   EMU_LEASE_HOST     ssh target holding the lease (default emu@android-emulator.tailbe5094.ts.net)
#   EMU_ADB_ENDPOINT   adb endpoint exported to the child (default android-emulator.tailbe5094.ts.net:5556)
#   EMU_LEASE_WAIT     seconds to wait for a busy lease (default 900)
#   EMU_LEASE_MAXHOLD  seconds before the lease auto-releases (default 7200 — the
#                      full 82-test suite runs ~80min; the lease is released the
#                      moment the command exits, so a long hold costs nothing)
#   EMU_REPO           repo path on the emulator LXC (default /opt/android-emulator)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_LOGDIR"

EMU_LEASE_HOST="${EMU_LEASE_HOST:-emu@android-emulator.tailbe5094.ts.net}"
EMU_ADB_ENDPOINT="${EMU_ADB_ENDPOINT:-android-emulator.tailbe5094.ts.net:5556}"
EMU_LEASE_WAIT="${EMU_LEASE_WAIT:-900}"
EMU_LEASE_MAXHOLD="${EMU_LEASE_MAXHOLD:-7200}"
EMU_REPO="${EMU_REPO:-/opt/android-emulator}"
LEASE="${EMU_LEASE:-/var/lib/android-emulator/lease}"

[[ "${1:-}" == "--" ]] && shift
if [[ $# -eq 0 ]]; then
  echo "Usage: scripts/with-fleet-emulator.sh -- <command...>" >&2
  exit 2
fi

log() { echo "> [fleet-emulator] $*" >&2; }
err() { echo "! [fleet-emulator] $*" >&2; }

# A backgrounded pty ssh holds the flock and boots the device, then signals READY
# on stdout. The remote `flock -w` blocks until any current holder releases; the
# pty means the remote side gets SIGHUP (and releases) when we disconnect.
# TOKEN ENFORCED 2026-08-12 (offer note): the emu ssh key is forced to a shim
# that only runs the flock lease command AND only with a hub-signed capability
# token. Acquire one via `hub acquire` (host verifies offline) and send it as a
# leading RELAYGENT_CAPTOKEN=<tok> on the lease command.
if ! command -v hub >/dev/null 2>&1; then
  err "hub CLI not found — the lease requires a capability token (hub acquire host@android-emulator emulator)"
  exit 2
fi
log "acquiring capability token (hub acquire host@android-emulator emulator)…"
captoken="$(hub acquire host@android-emulator emulator --ttl "$EMU_LEASE_MAXHOLD")" || {
  err "hub acquire failed — no capability token; the shim will DENY the lease"
  exit 1
}

sentinel="$(mktemp -u)"
mkfifo "$sentinel"
remote_cmd="RELAYGENT_CAPTOKEN=${captoken} flock -w ${EMU_LEASE_WAIT} -x ${LEASE} bash -c '
  ${EMU_REPO}/scripts/emu-ctl.sh ensure 2>&1 || { echo ENSURE_FAILED; exit 1; }
  echo READY
  sleep ${EMU_LEASE_MAXHOLD}'"

ssh -tt -o BatchMode=yes "$EMU_LEASE_HOST" "$remote_cmd" > "$sentinel" 2>/dev/null &
ssh_pid=$!

cleanup() {
  if kill -0 "$ssh_pid" 2>/dev/null; then
    kill "$ssh_pid" 2>/dev/null || true
  fi
  rm -f "$sentinel"
}
trap cleanup EXIT INT TERM

# Who is waiting: the hub identity this host enrolled as (the same one the
# capability token was minted for), so a fleet peer reading the log can tell
# whose run is queued.
hub_cfg="${AGENTHUB_CONFIG:-$HOME/.agenthub/config.toml}"
waiter="$(awk -F'"' '/^identity/ {i=$2} /^host/ {h=$2} END {if (i!="") print i "@" h}' "$hub_cfg" 2>/dev/null || true)"
waiter="${waiter:-$(whoami)@$(hostname)}"
wait_start=$(date +%s)
log "${waiter} acquiring lease on ${EMU_LEASE_HOST} for: $* (queue wait <= ${EMU_LEASE_WAIT}s, then cold boot ~135s; hold <= ${EMU_LEASE_MAXHOLD}s)…"
state=""
partial=""
phase="queued"   # queued = flock not yet ours (a peer holds it); booting = remote ensure is printing
granted_at=""
# Everything the remote ensure prints (docker build/boot progress) lands in the
# lease log — the 2026-09-12 "no space left on device" export failure was
# invisible while ensure ran silent.
lease_log="${MOBISSH_LOGDIR}/fleet-emulator-lease.log"
: > "$lease_log"
exec {sentinel_fd}< "$sentinel"
while true; do
  if IFS= read -r -t 30 -u "$sentinel_fd" line; then
    line="${partial}${line//$'\r'/}"; partial=""
    if [[ "$phase" == "queued" ]]; then
      phase="booting"; granted_at=$(date +%s)
      log "lease GRANTED after $((granted_at - wait_start))s queued — remote ensure/boot running (progress: ${lease_log})"
    fi
    case "$line" in
      READY)         state="ready"; break ;;
      ENSURE_FAILED) state="ensure_failed"; break ;;
      *)             printf '%s\n' "$line" >> "$lease_log" ;;
    esac
  else
    rc=$?
    (( rc > 128 )) || break   # EOF: the ssh holder exited (flock -w timeout, DENY, or ssh failure)
    partial+="$line"          # a timed-out read keeps the bytes it already consumed
    now=$(date +%s)
    if [[ "$phase" == "queued" ]]; then
      # The shim exposes no holder identity; the flock simply blocks until the
      # current holder's command exits or its hold expires.
      log "${waiter} still QUEUED for the emu lease on ${EMU_LEASE_HOST} — $((now - wait_start))s of ${EMU_LEASE_WAIT}s max; another holder's run must finish first"
    else
      log "${waiter} holds the lease; device ensure/boot running for $((now - granted_at))s (cold boot ~135s; tail ${lease_log})"
    fi
  fi
done
exec {sentinel_fd}<&-

if [[ "$state" != "ready" ]]; then
  err "lease NOT acquired: ${state:-timeout or ssh failure} (remote ensure output: ${lease_log})"
  err "check: ssh ${EMU_LEASE_HOST} ${EMU_REPO}/scripts/emu-ctl.sh status"
  exit 1
fi

log "lease held + device booted after $(( $(date +%s) - wait_start ))s total ($((granted_at - wait_start))s queued) → adb endpoint ${EMU_ADB_ENDPOINT}"

# Hand the leased device to the consumer scripts: connect-mode against the
# leased endpoint, and SKIP the retired container's ensure (#1098).
export EMU_CONTAINER=1
export EMU_ENSURE=0
export ADB_MODE=connect
export EMU_ADBD_ENDPOINT="$EMU_ADB_ENDPOINT"

hold_start=$(date +%s)
set +e
"$@"
rc=$?
set -e
held=$(( $(date +%s) - hold_start ))
# The remote `sleep MAXHOLD` is the hold: when it ends the flock drops and the
# device idle-stops under a still-running command. Every test after that fails
# "no online device" — device LOSS, not a regression (PR C suite, 2026-09-12).
if (( held >= EMU_LEASE_MAXHOLD )); then
  err "LEASE EXPIRED MID-RUN: command ran ${held}s >= EMU_LEASE_MAXHOLD=${EMU_LEASE_MAXHOLD}s — results after expiry are device loss, rerun with a longer EMU_LEASE_MAXHOLD"
fi
log "command exited rc=${rc} after ${held}s — releasing lease"
exit "$rc"
