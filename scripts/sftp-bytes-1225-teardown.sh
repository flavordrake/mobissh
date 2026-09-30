#!/usr/bin/env bash
# scripts/sftp-bytes-1225-teardown.sh — undo sftp-bytes-1225-setup.sh's relay:
# report how many READs the #1225 relay capped during the test, then switch the
# container's sftp subsystem back to the stock internal-sftp and HUP sshd, so
# later tests in the same run get the stock server. Honours SSHD_HOST.
#
# Runs as the test's declared Teardown, always (scripts/lib/integration-fixtures.sh).
set -euo pipefail

MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
WORK="${MOBISSH_TMPDIR}/sftp-bytes-1225"
mkdir -p "$WORK"
exec > >(tee -a "${WORK}/teardown.log") 2>&1

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${REPO_ROOT}/scripts/lib/sftp-cap-proxy.sh"
CONTAINER="$(sftpcap_container)"

echo "> relay counters for the test run in ${CONTAINER} ($(date +%Y%m%dT%H%M%S%z))"
sftpcap_report "$CONTAINER" || echo "  (no capped READs recorded)"

echo "> restoring ${SFTPCAP_STOCK_SUBSYSTEM}"
sftpcap_set_subsystem "$CONTAINER" "$SFTPCAP_STOCK_SUBSYSTEM"
echo "+ stock sftp subsystem restored in ${CONTAINER}"
