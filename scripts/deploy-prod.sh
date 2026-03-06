#!/usr/bin/env bash
# scripts/deploy-prod.sh
#
# Build and deploy the MobiSSH production container with Tailscale.
#
# Usage:
#   echo "tskey-auth-..." | scripts/deploy-prod.sh
#   scripts/deploy-prod.sh tskey-auth-...
#   scripts/deploy-prod.sh                      # skip auth (reuse persisted state)
#
# Options:
#   --tag <tag>       Image tag (default: latest)
#   --hostname <name> Tailscale hostname (default: mobissh)
#
# The auth key is read from: first arg, then stdin (if piped), then skipped.
# Skipping auth works if the container has previously authenticated and
# state is persisted in the tailscale-state volume.

set -euo pipefail

MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"
LOGFILE="${MOBISSH_LOGDIR}/deploy-prod.log"
exec > >(tee -a "$LOGFILE") 2>&1

TAG="latest"
TS_HOSTNAME="mobissh"
TS_AUTHKEY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --hostname) TS_HOSTNAME="$2"; shift 2 ;;
    tskey-*) TS_AUTHKEY="$1"; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# Read from stdin if piped and no key provided yet
if [[ -z "$TS_AUTHKEY" ]] && [[ ! -t 0 ]]; then
  read -r TS_AUTHKEY
fi

if [[ -z "$TS_AUTHKEY" ]]; then
  echo "No auth key provided -- reusing persisted Tailscale state"
fi

cd "$(dirname "$0")/.."

GIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
export TAG TS_HOSTNAME TS_AUTHKEY GIT_HASH

echo "Building mobissh:${TAG} (hostname: ${TS_HOSTNAME}, hash: ${GIT_HASH})"
docker compose -f docker-compose.prod.yml build --build-arg "GIT_HASH=${GIT_HASH}"
docker compose -f docker-compose.prod.yml up -d

echo "Waiting for container to start..."
sleep 3

if docker ps --filter name=mobissh-prod --format '{{.Status}}' | grep -q "Up"; then
  echo "Container running"
  docker logs --tail 10 mobissh-prod
else
  echo "Container failed to start" >&2
  docker logs mobissh-prod
  exit 1
fi
