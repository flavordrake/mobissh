#!/usr/bin/env bash
# scripts/native-release-apk.sh — Build + publish the native release APK.
#
# Captures the recurring delivery ritual (memory: feedback_apk_timestamp):
#   1. flutter build apk --release (signed with the release keystore — see
#      memory native-android-signing; falls back to debug cert if missing).
#   2. Copy to public/mobissh-native-<ISO-8601-ts>.apk AND the stable
#      public/mobissh-native.apk alias.
#   3. docker cp BOTH into mobissh-prod:/app/public/ so the running container
#      serves them immediately (the build caches the public/ COPY layer, so a
#      container rebuild would NOT pick up a new APK — copy directly).
#   4. Print the timestamped download URL to quote to the user.
#
# Run from the repo root. Exit 0 = published, 2 = build/setup error.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"
LOGFILE="${MOBISSH_LOGDIR}/native-release-apk.log"
exec > >(tee -a "$LOGFILE") 2>&1

NATIVE_DIR="${REPO_ROOT}/native"
PUBLIC_DIR="${REPO_ROOT}/public"
PROD_CONTAINER="mobissh-prod"
PROD_PUBLIC="/app/public"
SERVE_HOST="https://mobissh.tailbe5094.ts.net"
BUILT_APK="${NATIVE_DIR}/build/app/outputs/flutter-apk/app-release.apk"

TS="$(date +%Y%m%dT%H%M%S%z)"
STAMPED="mobissh-native-${TS}.apk"
STABLE="mobissh-native.apk"

log() { echo "> $*"; }
err() { echo "! $*" >&2; }

log "building native release APK (this can take a few minutes)..."
if ! "${REPO_ROOT}/scripts/flutter-cmd.sh" --in "$NATIVE_DIR" build apk --release; then
  err "flutter build apk --release failed"
  exit 2
fi

if [[ ! -f "$BUILT_APK" ]]; then
  err "expected APK not found at $BUILT_APK"
  exit 2
fi

log "publishing to ${PUBLIC_DIR}/ as ${STAMPED} + ${STABLE}"
cp "$BUILT_APK" "${PUBLIC_DIR}/${STAMPED}"
cp "$BUILT_APK" "${PUBLIC_DIR}/${STABLE}"

log "generating stable install landing page (public/native.html)"
"${REPO_ROOT}/scripts/gen-apk-install-page.sh" "$TS" "$STABLE" "$STAMPED"

log "copying APKs + install page into ${PROD_CONTAINER}:${PROD_PUBLIC}/ (live serve)"
docker cp "${PUBLIC_DIR}/${STAMPED}" "${PROD_CONTAINER}:${PROD_PUBLIC}/${STAMPED}"
docker cp "${PUBLIC_DIR}/${STABLE}" "${PROD_CONTAINER}:${PROD_PUBLIC}/${STABLE}"
docker cp "${PUBLIC_DIR}/native.html" "${PROD_CONTAINER}:${PROD_PUBLIC}/native.html"
docker cp "${PUBLIC_DIR}/native-time.js" "${PROD_CONTAINER}:${PROD_PUBLIC}/native-time.js"

echo "+ PUBLISHED"
echo "+ install page (bookmark this, refresh for latest):"
echo "  ${SERVE_HOST}/native.html"
echo "+ stable apk:  ${SERVE_HOST}/${STABLE}"
echo "+ this build:  ${SERVE_HOST}/${STAMPED}"
