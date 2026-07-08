#!/usr/bin/env bash
# scripts/cc-exec-switch-setup.sh — pre-create a PERSISTENT tmux `main` session
# with THREE named windows, each holding a DISTINCT on-screen marker, BEFORE the
# app connects, for the cc_exec_switch emulator test (#906 "not switching").
#
# THE BUG this reproduces: on `tmux -CC attach` to a PRE-EXISTING session, tmux
# emits NO `%window-add`/`%layout-change` for the windows that existed before the
# client attached (verified against real tmux -CC). So MobiSSH's channel window
# order stays EMPTY → a status-bar tap resolves to null → NO `select-window` →
# no switch. cc_gestures passes only because it CREATES windows AFTER attach
# (emitting %window-add); the owner attaches a PRE-POPULATED session.
#
# The windows exist BEFORE the app connects, so the app must QUERY the window
# list (`list-windows`) on attach to make the tap resolvable — the fix under
# test. Window 0 (alpha) is left ACTIVE, so a tap on the LAST status segment
# must switch to window 2 (charlie) and repaint its CHARLIE marker.
#
# Run immediately before scripts/native-connect-test.sh
# integration_test/cc_exec_switch_test.dart
set -euo pipefail

MOBISSH_CC_DIR="${MOBISSH_CC_DIR:-/tmp/mobissh/cc-exec-switch}"
mkdir -p "$MOBISSH_CC_DIR"
LOGFILE="${MOBISSH_CC_DIR}/setup.log"
exec > >(tee -a "$LOGFILE") 2>&1

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY="${MOBISSH_CC_DIR}/testuser_key"
cp "${REPO_ROOT}/docker/test-sshd/testuser_id_ed25519" "$KEY"
chmod 600 "$KEY"

echo "> pre-creating persistent tmux 'main' with 3 marker windows ($(date +%Y%m%dT%H%M%S%z))"
ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  testuser@test-sshd '
rm -f /home/testuser/.bash_profile
tmux kill-server >/dev/null 2>&1 || true
# Create all 3 windows FIRST, then let every windows shell finish printing its
# login MOTD before painting markers (a send-keys into a not-yet-ready shell is
# lost — the marker then never renders). alpha stays active (created first).
tmux new-session -d -s main -n alpha -x 80 -y 24
tmux new-window -t main -n bravo
tmux new-window -t main -n charlie
sleep 2
# Paint each windows marker on its OWN screen (clear wipes the MOTD), then wait
# so the echo lands before the next step.
tmux send-keys -t main:alpha "clear; echo WIN_ALPHA_MARKER_000" Enter
tmux send-keys -t main:bravo "clear; echo WIN_BRAVO_MARKER_111" Enter
tmux send-keys -t main:charlie "clear; echo WIN_CHARLIE_MARKER_222" Enter
sleep 2
tmux select-window -t main:alpha
sleep 1
echo "windows (tmux truth, alpha active):"
tmux list-windows -t main -F "#{window_id} #{window_index} #{window_name} active=#{window_active}"
echo "alpha capture (must contain WIN_ALPHA_MARKER):"
tmux capture-pane -p -t main:alpha
echo "charlie capture (must contain WIN_CHARLIE_MARKER):"
tmux capture-pane -p -t main:charlie
'
echo "+ persistent main ready: alpha(active)/bravo/charlie, each with a marker"
