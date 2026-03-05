#!/usr/bin/env bash
# scripts/deploy-prod.sh
#
# Build and deploy the MobiSSH production container.
#
# Usage:
#   scripts/deploy-prod.sh           # build from HEAD, tag as latest
#   scripts/deploy-prod.sh v0.5.0   # build from HEAD, tag as v0.5.0
#
# Requires: Docker with compose plugin

set -euo pipefail

MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"
LOGFILE="${MOBISSH_LOGDIR}/deploy-prod.log"
exec > >(tee -a "$LOGFILE") 2>&1

TAG="${1:-latest}"
export TAG

cd "$(dirname "$0")/.."

echo "Building and deploying mobissh:${TAG} on port 8082"
docker compose -f docker-compose.prod.yml up -d --build

CONTAINER_ID=$(docker inspect --format '{{.Id}}' mobissh-prod)
echo "Running: ${CONTAINER_ID}"
