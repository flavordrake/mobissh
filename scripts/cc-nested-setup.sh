#!/usr/bin/env bash
# scripts/cc-nested-setup.sh — reproduce the OWNER'S real environment on test-sshd
# for the #982 control-mode brick: a NESTED tmux (the login shell auto-attaches a
# persistent session) with a UTF-8 status line.
#
# The owner's login auto-attaches tmux, so MobiSSH's shell channel lands INSIDE
# tmux. The app then types `tmux -CC attach ...` into that inner pane, where -CC
# can NEVER attach (nested) → the control-mode handshake never completes → the
# parser swallows the real terminal bytes and the refresh-client resize commands
# leak into the pane as text. Control mode ON BRICKS the connection.
#
# This fixture installs a ~/.bash_profile guard that execs `tmux attach -t main`
# for interactive shells, and pre-creates `main` with a UTF-8 status line + a
# distinctive on-screen marker. Restore with scripts/cc-nested-teardown.sh.
#
# Run immediately before scripts/native-connect-test.sh
# integration_test/cc_nested_fallback_test.dart
set -euo pipefail

MOBISSH_CC_DIR="${MOBISSH_CC_DIR:-/tmp/mobissh/cc-nested}"
mkdir -p "$MOBISSH_CC_DIR"
LOGFILE="${MOBISSH_CC_DIR}/setup.log"
exec > >(tee -a "$LOGFILE") 2>&1

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY="${MOBISSH_CC_DIR}/testuser_key"
cp "${REPO_ROOT}/docker/test-sshd/testuser_id_ed25519" "$KEY"
chmod 600 "$KEY"

echo "> installing NESTED-tmux login guard + UTF-8 status main session ($(date +%Y%m%dT%H%M%S%z))"
ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  testuser@test-sshd '
tmux kill-server >/dev/null 2>&1 || true
printf "set -g mouse on\nset -g history-limit 5000\nset -g status on\nset -g status-left \"MOBI-star-B\"\n" > /home/testuser/.tmux.conf
printf "%s\n" "[ -z \"\$TMUX\" ] && [ -t 0 ] && exec tmux attach -t main" > /home/testuser/.bash_profile
tmux new-session -d -s main -n main -x 80 -y 24
tmux send-keys -t main "clear; echo NESTED_SCREEN_MARKER_done" Enter
sleep 1
echo "sessions:"; tmux list-sessions
echo "profile:"; cat /home/testuser/.bash_profile
'
echo "+ nested main session ready (auto-attach on login, UTF-8 status line)"
