#!/usr/bin/env bash
# scripts/cc-nested-teardown.sh — undo scripts/cc-nested-setup.sh so subsequent
# tests get a PLAIN (non-nested) login shell again. Removes the ~/.bash_profile
# auto-attach guard and kills the tmux server.
set -euo pipefail

MOBISSH_CC_DIR="${MOBISSH_CC_DIR:-/tmp/mobissh/cc-nested}"
mkdir -p "$MOBISSH_CC_DIR"
LOGFILE="${MOBISSH_CC_DIR}/teardown.log"
exec > >(tee -a "$LOGFILE") 2>&1

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY="${MOBISSH_CC_DIR}/testuser_key"
cp "${REPO_ROOT}/docker/test-sshd/testuser_id_ed25519" "$KEY"
chmod 600 "$KEY"

echo "> removing NESTED-tmux login guard ($(date +%Y%m%dT%H%M%S%z))"
ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  testuser@test-sshd '
rm -f /home/testuser/.bash_profile
tmux kill-server >/dev/null 2>&1 || true
echo "profile removed; tmux server killed"
'
echo "+ nested guard removed — login shell is plain again"
