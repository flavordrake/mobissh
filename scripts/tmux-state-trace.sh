#!/usr/bin/env bash
# scripts/tmux-state-trace.sh — observe the REAL tmux server's ground truth so
# app-side symptoms (stale paint, swipe/tap landing on the wrong row, "works
# then doesn't") can be correlated to the remote sync state the client can't see.
#
# WHY: the recurring MobiSSH terminal bugs are a desync between three sizes — the
# phone's flutter grid, what we sent the PTY, and tmux's EFFECTIVE size under
# MULTIPLE clients (window-size latest flips by activity). The SSH target IS this
# container, so we can read tmux's truth directly. This logs the client topology
# + sizes + window-size mode + effective window dims, timestamped, on every tmux
# resize/attach/detach so a bug report at time T aligns to the remote state at T.
#
# Usage:
#   scripts/tmux-state-trace.sh snapshot     one-shot: print + log current state
#   scripts/tmux-state-trace.sh watch        install tmux hooks → log every churn
#   scripts/tmux-state-trace.sh off          remove the hooks
#   scripts/tmux-state-trace.sh tail [N]     show the last N log lines (default 40)
#   scripts/tmux-state-trace.sh _emit EVENT  (internal — called by the hooks)
set -euo pipefail

MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_LOGDIR"
LOGFILE="${MOBISSH_LOGDIR}/tmux-state.log"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# Hooks we own (global). client-resized is the key churn signal; attach/detach
# change the client set window-size follows; session-window-changed catches a
# window switch (the gesture under test).
HOOKS="client-resized client-attached client-detached client-session-changed session-window-changed"

_ts() { date +%Y%m%dT%H%M%S%z; }

# One structured line: timestamp, event, window-size mode, effective active
# window dims, and EVERY client's tty=WxH@last-activity. The clients list is the
# crux — it shows multi-client churn and which client tmux is currently sized to.
_emit() {
  local ev="${1:-tick}" ts winsize win clients
  ts="$(_ts)"
  winsize="$(tmux show -gv window-size 2>/dev/null || echo '?')"
  win="$(tmux list-windows -a -F '#{session_name}:#{window_name}=#{window_width}x#{window_height}' -f '#{window_active}' 2>/dev/null | tr '\n' ',' || echo '?')"
  clients="$(tmux list-clients -F '#{client_tty}=#{client_width}x#{client_height}@#{client_activity}' 2>/dev/null | tr '\n' ',' || echo '?')"
  printf '%s ev=%-22s winsize=%s activewin=[%s] clients=[%s]\n' \
    "$ts" "$ev" "$winsize" "$win" "$clients" >>"$LOGFILE"
}

case "${1:-}" in
  snapshot)
    _emit "snapshot"
    tail -n 1 "$LOGFILE"
    ;;
  watch)
    for h in $HOOKS; do
      tmux set-hook -g "$h" "run-shell -b '$SELF _emit $h'"
    done
    _emit "watch-armed"
    echo "+ tmux-state-trace armed on: $HOOKS"
    echo "  logging to $LOGFILE"
    ;;
  off)
    for h in $HOOKS; do
      tmux set-hook -gu "$h" || true
    done
    _emit "watch-disarmed"
    echo "+ tmux-state-trace hooks removed"
    ;;
  tail)
    tail -n "${2:-40}" "$LOGFILE"
    ;;
  _emit)
    _emit "${2:-tick}"
    ;;
  *)
    echo "usage: $0 {snapshot|watch|off|tail [N]}" >&2
    exit 2
    ;;
esac
