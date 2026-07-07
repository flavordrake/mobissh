#!/usr/bin/env bash
# scripts/cc-scroll-setup.sh — pre-create a PERSISTENT tmux `main` session on
# test-sshd whose ACTIVE pane holds 200 NUMBERED lines (LINE_001..LINE_200), far
# exceeding the viewport, for the cc_capture_scroll emulator test (#906 Stage 2).
#
# Stage 2 scrolls the `-CC` scrollback by REQUESTING `capture-pane -S -E` history
# windows (control mode emits no `%output` for copy-mode scroll, so the local grid
# can't show it). To PROVE it we need a pane whose history holds known early line
# numbers that are NOT on the initial (tail) screen — so seeing e.g. LINE_005 can
# ONLY be the scrollback capture, never the live tail.
#
# Run this immediately before scripts/native-connect-test.sh
# integration_test/cc_capture_scroll_test.dart
set -euo pipefail

MOBISSH_CC_DIR="${MOBISSH_CC_DIR:-/tmp/mobissh/cc-scroll}"
mkdir -p "$MOBISSH_CC_DIR"
LOGFILE="${MOBISSH_CC_DIR}/setup.log"
exec > >(tee -a "$LOGFILE") 2>&1

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY="${MOBISSH_CC_DIR}/testuser_key"
cp "${REPO_ROOT}/docker/test-sshd/testuser_id_ed25519" "$KEY"
chmod 600 "$KEY"

echo "> pre-creating persistent tmux 'main' with 200 numbered lines ($(date +%Y%m%dT%H%M%S%z))"
ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  testuser@test-sshd '
tmux kill-server >/dev/null 2>&1 || true
tmux new-session -d -s main -n WSCROLL -x 80 -y 24
tmux send-keys -t main:WSCROLL "clear; awk '"'"'BEGIN{for(i=1;i<=200;i++)printf \"LINE_%03d\\n\", i}'"'"'" Enter
sleep 2
echo "sessions:"; tmux list-sessions
echo "history size:"; tmux display-message -p -t main:WSCROLL "#{history_size}"
echo "tail (initial visible screen):"; tmux capture-pane -p -t main:WSCROLL
'
echo "+ persistent main session ready (WSCROLL: LINE_001..LINE_200, tail visible)"
