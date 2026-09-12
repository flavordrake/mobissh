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
#   EMU_LEASE_MAXHOLD  seconds before the lease auto-releases (default 3600)
#   EMU_REPO           repo path on the emulator LXC (default /opt/android-emulator)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_LOGDIR"

EMU_LEASE_HOST="${EMU_LEASE_HOST:-emu@android-emulator.tailbe5094.ts.net}"
EMU_ADB_ENDPOINT="${EMU_ADB_ENDPOINT:-android-emulator.tailbe5094.ts.net:5556}"
EMU_LEASE_WAIT="${EMU_LEASE_WAIT:-900}"
EMU_LEASE_MAXHOLD="${EMU_LEASE_MAXHOLD:-3600}"
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

log "acquiring lease on ${EMU_LEASE_HOST} (wait <= ${EMU_LEASE_WAIT}s; cold boot ~135s)…"
state=""
# Everything the remote ensure prints (docker build/boot progress) lands in the
# lease log — the 2026-09-12 "no space left on device" export failure was
# invisible while ensure ran silent.
lease_log="${MOBISSH_LOGDIR}/fleet-emulator-lease.log"
: > "$lease_log"
while IFS= read -r line; do
  line="${line//$'\r'/}"
  case "$line" in
    READY)         state="ready"; break ;;
    ENSURE_FAILED) state="ensure_failed"; break ;;
    *)             printf '%s\n' "$line" >> "$lease_log" ;;
  esac
done < "$sentinel"

if [[ "$state" != "ready" ]]; then
  err "lease NOT acquired: ${state:-timeout or ssh failure} (remote ensure output: ${lease_log})"
  err "check: ssh ${EMU_LEASE_HOST} ${EMU_REPO}/scripts/emu-ctl.sh status"
  exit 1
fi

log "lease held + device booted → adb endpoint ${EMU_ADB_ENDPOINT}"

# Hand the leased device to the consumer scripts: connect-mode against the
# leased endpoint, and SKIP the retired container's ensure (#1098).
export EMU_CONTAINER=1
export EMU_ENSURE=0
export ADB_MODE=connect
export EMU_ADBD_ENDPOINT="$EMU_ADB_ENDPOINT"

set +e
"$@"
rc=$?
set -e
log "command exited rc=${rc} — releasing lease"
exit "$rc"
