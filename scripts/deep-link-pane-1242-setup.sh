#!/usr/bin/env bash
# scripts/deep-link-pane-1242-setup.sh — pre-create tmux session `p1242` on
# test-sshd for the deep_link_pane_1242 emulator test (#1242 S1).
#
# `p1242` holds window `alpha` (one pane, current) and window `beta` with TWO
# panes (pane 0 active). The test attaches to it BY HAND in the PTY (the
# owner's env: tmux started by the user, not by a link), then fires
# `tmux=p1242&window=@N&pane=%N` at `beta` pane 1. The ids are discovered by
# the test over its own exec connection, so none are fixed here. `q1242` (a
# second session) is created and removed by the test itself; this script only
# clears a leftover one. Other sessions survive.
#
# Runs as the test's declared Setup (scripts/lib/integration-fixtures.sh).
# Honours SSHD_HOST: the runner pins it to an unambiguous container.
set -euo pipefail

MOBISSH_P1242_DIR="${MOBISSH_P1242_DIR:-/tmp/mobissh/deep-link-pane-1242}"
mkdir -p "$MOBISSH_P1242_DIR"
LOGFILE="${MOBISSH_P1242_DIR}/setup.log"
exec > >(tee -a "$LOGFILE") 2>&1

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY="${MOBISSH_P1242_DIR}/testuser_key"
cp "${REPO_ROOT}/docker/test-sshd/testuser_id_ed25519" "$KEY"
chmod 600 "$KEY"

echo "> creating tmux p1242 (alpha; beta with 2 panes) on ${SSHD_HOST:-test-sshd} ($(date +%Y%m%dT%H%M%S%z))"
ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "testuser@${SSHD_HOST:-test-sshd}" '
for s in p1242 q1242; do
  if tmux has-session -t "=$s" 2>/dev/null; then tmux kill-session -t "=$s"; fi
done
tmux new-session -d -s p1242 -n alpha
tmux new-window -d -t =p1242 -n beta
tmux split-window -d -t "=p1242:=beta"
tmux select-pane -t "=p1242:=beta.0"
tmux select-window -t "=p1242:=alpha"
tmux list-panes -a -F "#{session_name} #{window_name} #{window_id} #{pane_id} idx=#{pane_index}" | grep "^p1242 "
'
echo "+ p1242 ready (alpha current; beta has 2 panes)"
