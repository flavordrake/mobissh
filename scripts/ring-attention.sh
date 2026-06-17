#!/usr/bin/env bash
# scripts/ring-attention.sh — fire a synthetic "Claude needs attention" signal
# at the owner's attached tmux client on THIS host (fd-dev is the SSH target).
#
# Emits an OSC9 notification sequence directly to the client tty (post-tmux,
# raw down the SSH channel), which MobiSSH's AttentionSignalScanner picks up →
# posts the attention notification for this host. Used to trigger on-demand
# repros of notification routing (#857/#870 wrong-host tap) without waiting for
# a real agent event.
#
# Usage: scripts/ring-attention.sh [message]
set -euo pipefail
cd "$(dirname "$0")/.."

MSG="${1:-Claude needs attention (synthetic repro ring)}"

CLIENT_TTY="$(tmux list-clients -F '#{client_tty}' | head -1)"
if [ -z "$CLIENT_TTY" ]; then
  echo "! ring-attention: no attached tmux client found" >&2
  exit 1
fi

printf '\033]9;%s\007' "$MSG" > "$CLIENT_TTY"
echo "+ rang OSC9 attention on $CLIENT_TTY: $MSG"
