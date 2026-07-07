#!/usr/bin/env bash
# scripts/cc-capture-setup.sh — pre-create a PERSISTENT tmux `main` session on
# test-sshd whose ACTIVE pane holds a STATIC, distinctive screen and produces NO
# ongoing output, for the cc_capture_attach emulator test (#906 Stage 1).
#
# Stage 1 renders the attached pane by REQUESTING `capture-pane` (real -CC clients
# do this; MobiSSH's old path showed only new %output, so an idle attach stayed
# blank). To PROVE the capture render we need a session that exists BEFORE the app
# connects, whose visible screen contains a known marker and is otherwise quiet —
# so the marker can ONLY reach the grid via capture-pane, never via live %output.
#
# Run this immediately before scripts/native-connect-test.sh
# integration_test/cc_capture_attach_test.dart
set -euo pipefail

MOBISSH_CC_DIR="${MOBISSH_CC_DIR:-/tmp/mobissh/cc-capture}"
mkdir -p "$MOBISSH_CC_DIR"
LOGFILE="${MOBISSH_CC_DIR}/setup.log"
exec > >(tee -a "$LOGFILE") 2>&1

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY="${MOBISSH_CC_DIR}/testuser_key"
cp "${REPO_ROOT}/docker/test-sshd/testuser_id_ed25519" "$KEY"
chmod 600 "$KEY"

echo "> pre-creating persistent tmux 'main' with a STATIC marker screen ($(date +%Y%m%dT%H%M%S%z))"
ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  testuser@test-sshd '
tmux kill-server >/dev/null 2>&1 || true
tmux new-session -d -s main -n WCAP -x 80 -y 24
tmux send-keys -t main:WCAP "clear; echo CAPTURE_SCREEN_MARKER_XYZ" Enter
sleep 1
echo "sessions:"; tmux list-sessions
echo "capture (what -CC attach must render):"
tmux capture-pane -p -t main:WCAP
'
echo "+ persistent main session ready (WCAP holds CAPTURE_SCREEN_MARKER_XYZ, idle)"
