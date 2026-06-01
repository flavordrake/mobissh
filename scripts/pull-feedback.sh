#!/usr/bin/env bash
# scripts/pull-feedback.sh — Pull version-scoped feedback from the prod container
# into the dev workspace so the orchestrator can read + triage it (#609).
#
# The install-page feedback form (native.html) POSTs to /api/bug-report, which
# saves into the PROD container's /app/test-results/uploads/. This dev session
# can't see that dir directly, so this script docker-cp's new uploads into the
# local test-results/uploads/ (the dir the orchestrator watches per memory).
#
# Each report is a trio: <ts>-bug-report.{json,log,png}. The .json carries the
# `version` field (build stamp + commit) so feedback is tied to exactly what was
# shipping when it was hit.
#
# Usage: scripts/pull-feedback.sh [--list]
#   (no args)  copy any uploads not already local, then list what's new
#   --list     just list reports in the prod container, newest first

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROD_CONTAINER="mobissh-prod"
PROD_UPLOADS="/app/test-results/uploads"
LOCAL_UPLOADS="${REPO_ROOT}/test-results/uploads"

log() { echo "> $*"; }

if [[ "${1:-}" == "--list" ]]; then
  docker exec "$PROD_CONTAINER" sh -c "ls -t ${PROD_UPLOADS} 2>/dev/null | grep bug-report.json" || log "no feedback reports yet"
  exit 0
fi

mkdir -p "$LOCAL_UPLOADS"

# Names of every upload file in prod (the whole dir is small — copy what's
# missing locally). Use a temp listing to avoid a pipe-in-loop.
listing="$(docker exec "$PROD_CONTAINER" sh -c "ls ${PROD_UPLOADS} 2>/dev/null" || true)"
if [[ -z "$listing" ]]; then
  log "no uploads in ${PROD_CONTAINER}:${PROD_UPLOADS}"
  exit 0
fi

new_count=0
while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  if [[ ! -e "${LOCAL_UPLOADS}/${name}" ]]; then
    docker cp "${PROD_CONTAINER}:${PROD_UPLOADS}/${name}" "${LOCAL_UPLOADS}/${name}"
    new_count=$((new_count + 1))
  fi
done <<< "$listing"

log "pulled ${new_count} new file(s) into ${LOCAL_UPLOADS}"

# Surface the feedback reports (the .json carries version + title), newest first.
if ls "${LOCAL_UPLOADS}"/*bug-report.json >/dev/null 2>&1; then
  log "feedback reports (newest first):"
  ls -t "${LOCAL_UPLOADS}"/*bug-report.json
fi
