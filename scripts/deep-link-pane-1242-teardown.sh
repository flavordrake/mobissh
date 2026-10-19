#!/usr/bin/env bash
# scripts/deep-link-pane-1242-teardown.sh — remove the tmux sessions the
# deep_link_pane_1242 emulator test used (`p1242`, `q1242`) from test-sshd.
# Runs as the test's declared Teardown, always, including after a failure.
# Only those two sessions are touched; every other session survives.
set -euo pipefail

MOBISSH_P1242_DIR="${MOBISSH_P1242_DIR:-/tmp/mobissh/deep-link-pane-1242}"
mkdir -p "$MOBISSH_P1242_DIR"
LOGFILE="${MOBISSH_P1242_DIR}/teardown.log"
exec > >(tee -a "$LOGFILE") 2>&1

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY="${MOBISSH_P1242_DIR}/testuser_key"
cp "${REPO_ROOT}/docker/test-sshd/testuser_id_ed25519" "$KEY"
chmod 600 "$KEY"

echo "> removing tmux p1242 / q1242 on ${SSHD_HOST:-test-sshd} ($(date +%Y%m%dT%H%M%S%z))"
ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "testuser@${SSHD_HOST:-test-sshd}" '
for s in p1242 q1242; do
  if tmux has-session -t "=$s" 2>/dev/null; then tmux kill-session -t "=$s"; fi
done
'
echo "+ p1242 / q1242 removed"
