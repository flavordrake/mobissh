#!/usr/bin/env bash
# scripts/testsshd-tailnet-bridge.sh — expose test-sshd:22 to TAILNET PEERS on
# fd-dev's tailnet address, port 2222 (#1026 slice: test-sshd reachability from
# the mac-runner).
#
# test-sshd is a Docker sibling with no published port (docker-proxy is not
# available here), reachable only via Docker DNS on the `mobissh` network. The
# mac-runner (matts-macbook-air) is a tailnet peer, not a Docker peer — so this
# script runs a detached socat that listens on fd-dev's tailnet IPv4 (from
# `tailscale ip -4`) and forwards to test-sshd:22. Binding the tailnet address
# SPECIFICALLY (never 0.0.0.0) keeps the fixture tailnet-only AND avoids the
# known local users of port 2222: native-connect-test.sh's socat binds
# 127.0.0.1:2222 (different address, no clash — verified via ss). If the
# tailnet address:2222 is ever taken by someone else, override with
# MOBISSH_TAILNET_BRIDGE_PORT=2223.
#
# On the Mac, mac-connect-test.sh adds the second hop
# (127.0.0.1:2222 → fd-dev:2222 over the tailnet) so the committed integration
# tests run UNCHANGED against 127.0.0.1:2222 on every target.
#
# Usage: scripts/testsshd-tailnet-bridge.sh {start|stop|status}
#   start   idempotent: reuse a live bridge, else launch detached socat.
#           Verifies test-sshd:22 is reachable first (runs test-sshd-up.sh if not).
#   stop    kill the bridge, remove the pidfile.
#   status  print bridge endpoint + pid; exit 0 up, 1 down.
#
# Env: MOBISSH_TAILNET_BRIDGE_PORT (default 2222)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"
PID_FILE="${MOBISSH_TMPDIR}/testsshd-tailnet-bridge.pid"
LOGFILE="${MOBISSH_LOGDIR}/testsshd-tailnet-bridge.log"

BRIDGE_PORT="${MOBISSH_TAILNET_BRIDGE_PORT:-2222}"
SSHD_HOST="test-sshd"
SSHD_PORT="22"

log() { echo "> $*"; }
err() { echo "! $*" >&2; }

tailnet_ip() {
  tailscale ip -4 2>/dev/null | head -n1
}

bridge_pid() {
  # Live pid from the pidfile, or empty.
  local pid
  [[ -f "$PID_FILE" ]] || return 0
  pid="$(cat "$PID_FILE")"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    echo "$pid"
  fi
}

sshd_reachable() {
  timeout 3 bash -c "exec 3<>/dev/tcp/${SSHD_HOST}/${SSHD_PORT}" 2>/dev/null
}

port_holder() {
  # Who (if anyone) listens on $1:$BRIDGE_PORT. Empty output = free.
  ss -ltnpH "src ${1}:${BRIDGE_PORT}" 2>/dev/null || true
}

cmd="${1:-status}"
case "$cmd" in
  start)
    if ! command -v socat >/dev/null 2>&1; then
      err "socat not installed"; exit 2
    fi
    TS_IP="$(tailnet_ip)"
    if [[ -z "$TS_IP" ]]; then
      err "no tailnet IPv4 (is tailscale up?)"; exit 2
    fi
    pid="$(bridge_pid)"
    if [[ -n "$pid" ]]; then
      log "reusing live bridge (pid $pid) on ${TS_IP}:${BRIDGE_PORT}"
      exit 0
    fi
    holder="$(port_holder "$TS_IP")"
    if [[ -n "$holder" ]]; then
      err "${TS_IP}:${BRIDGE_PORT} already bound by another process:"
      err "  $holder"
      err "retry with MOBISSH_TAILNET_BRIDGE_PORT=2223"
      exit 2
    fi
    if ! sshd_reachable; then
      log "test-sshd:22 not reachable — running test-sshd-up.sh"
      "$REPO_ROOT/scripts/test-sshd-up.sh"
      if ! sshd_reachable; then
        err "test-sshd:22 still unreachable after test-sshd-up.sh"; exit 2
      fi
    fi
    log "starting bridge ${TS_IP}:${BRIDGE_PORT} -> ${SSHD_HOST}:${SSHD_PORT} ($(date +%Y%m%dT%H%M%S%z))"
    setsid nohup socat "TCP-LISTEN:${BRIDGE_PORT},bind=${TS_IP},fork,reuseaddr" \
      "TCP:${SSHD_HOST}:${SSHD_PORT}" >>"$LOGFILE" 2>&1 &
    echo $! > "$PID_FILE"
    sleep 0.3
    pid="$(bridge_pid)"
    if [[ -z "$pid" ]]; then
      err "socat exited immediately — see $LOGFILE"
      rm -f "$PID_FILE"
      exit 2
    fi
    log "bridge up (pid $pid); tailnet peers reach the fixture at ${TS_IP}:${BRIDGE_PORT}"
    ;;
  stop)
    pid="$(bridge_pid)"
    if [[ -n "$pid" ]]; then
      log "stopping bridge (pid $pid)"
      kill "$pid" 2>/dev/null || true
    else
      log "no live bridge"
    fi
    rm -f "$PID_FILE"
    ;;
  status)
    TS_IP="$(tailnet_ip)"
    pid="$(bridge_pid)"
    if [[ -n "$pid" ]]; then
      echo "up: pid $pid, ${TS_IP:-<no-tailnet-ip>}:${BRIDGE_PORT} -> ${SSHD_HOST}:${SSHD_PORT}"
      exit 0
    fi
    echo "down"
    exit 1
    ;;
  *)
    err "usage: testsshd-tailnet-bridge.sh {start|stop|status}"; exit 2
    ;;
esac
