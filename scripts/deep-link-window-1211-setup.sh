#!/usr/bin/env bash
# scripts/deep-link-window-1211-setup.sh — pre-create tmux session `w1211` on
# test-sshd with two NAMED windows (`alpha`, `beta`; `alpha` current) for the
# deep_link_window_1211 emulator test (#1211).
#
# The test fires `mobissh://…tmux=w1211&window=beta` and asserts the attached
# client lands on `beta`, so the session must already hold both windows and
# must NOT start on `beta`. Only `w1211` is replaced; other sessions survive.
#
# Runs as the test's declared Setup (scripts/lib/integration-fixtures.sh).
set -euo pipefail

MOBISSH_W1211_DIR="${MOBISSH_W1211_DIR:-/tmp/mobissh/deep-link-window-1211}"
mkdir -p "$MOBISSH_W1211_DIR"
LOGFILE="${MOBISSH_W1211_DIR}/setup.log"
exec > >(tee -a "$LOGFILE") 2>&1

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY="${MOBISSH_W1211_DIR}/testuser_key"
cp "${REPO_ROOT}/docker/test-sshd/testuser_id_ed25519" "$KEY"
chmod 600 "$KEY"

echo "> creating tmux w1211 (alpha, beta) on ${SSHD_HOST:-test-sshd} ($(date +%Y%m%dT%H%M%S%z))"
ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "testuser@${SSHD_HOST:-test-sshd}" '
tmux kill-session -t =w1211 >/dev/null 2>&1 || true
tmux new-session -d -s w1211 -n alpha
tmux new-window -d -t =w1211 -n beta
tmux select-window -t "=w1211:=alpha"
echo "windows:"; tmux list-windows -t =w1211 -F "#{window_index} #{window_name} active=#{window_active}"
'
echo "+ w1211 ready (alpha current, beta present)"
