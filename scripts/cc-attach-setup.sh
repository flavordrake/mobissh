#!/usr/bin/env bash
# scripts/cc-attach-setup.sh — pre-create a PERSISTENT tmux `main` session on
# test-sshd for the cc_attach_existing emulator test (#906).
#
# The test connects with control mode ON and must attach the owner's EXISTING
# session (`tmux -CC attach`), not a separate one. To prove attach-EXISTING the
# session must exist BEFORE the app connects and must NOT be one the app created.
# This creates a clean `main` with two named windows, each echoing a distinct
# marker into its pane, then leaves it detached (server-side, survives).
#
# Run this immediately before scripts/native-connect-test.sh
# integration_test/cc_attach_existing_test.dart
set -euo pipefail

MOBISSH_CC_DIR="${MOBISSH_CC_DIR:-/tmp/mobissh/cc-attach}"
mkdir -p "$MOBISSH_CC_DIR"
LOGFILE="${MOBISSH_CC_DIR}/setup.log"
exec > >(tee -a "$LOGFILE") 2>&1

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY="${MOBISSH_CC_DIR}/testuser_key"
cp "${REPO_ROOT}/docker/test-sshd/testuser_id_ed25519" "$KEY"
chmod 600 "$KEY"

echo "> pre-creating persistent tmux 'main' on test-sshd ($(date +%Y%m%dT%H%M%S%z))"
ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  testuser@test-sshd '
tmux kill-server >/dev/null 2>&1 || true
tmux new-session -d -s main -n WEXIST0
tmux new-window -t main -n WEXIST1
tmux send-keys -t main:WEXIST0 "echo ATTACH_MARK_ZERO" Enter
tmux send-keys -t main:WEXIST1 "echo ATTACH_MARK_ONE" Enter
sleep 1
echo "sessions:"; tmux list-sessions
echo "windows:"; tmux list-windows -t main
'
echo "+ persistent main session ready (WEXIST0/WEXIST1 + markers)"
