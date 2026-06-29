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
# #dx: --split-per-abi builds one small single-ABI APK per architecture instead
# of one fat ~91MB APK with all three. arm64-v8a (every modern phone) is the
# PRIMARY published download (~30MB → ~3x faster download + install); the
# armeabi-v7a / x86_64 splits are published as fallbacks for other devices.
APK_DIR="${NATIVE_DIR}/build/app/outputs/flutter-apk"
BUILT_APK="${APK_DIR}/app-arm64-v8a-release.apk"
FALLBACK_V7A="${APK_DIR}/app-armeabi-v7a-release.apk"
FALLBACK_X64="${APK_DIR}/app-x86_64-release.apk"
# Persistent, bind-mounted native distribution dir (#700). docker-compose.prod.yml
# mounts this host path at the container's /app/native-dist, and server/index.js
# serves the native artifact names from there — so the APK + install page survive
# a container recreate AND the `container-ctl.sh push` hot-cp of public/ (the old
# docker-cp-into-/app/public approach was wiped by both). FIXED host path (the main
# checkout, = the mounted volume), independent of which worktree built the APK.
NATIVE_DIST_HOST="${NATIVE_DIST_HOST:-/home/dev/workspace/mobissh/native-dist}"

TS="$(date +%Y%m%dT%H%M%S%z)"
STAMPED="mobissh-native-${TS}.apk"
STABLE="mobissh-native.apk"
# The commit the APK is built from — passed to the page generator so the page's
# displayed hash ALWAYS matches the binary (never live HEAD on a page-only regen).
BUILD_COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"

log() { echo "> $*"; }
err() { echo "! $*" >&2; }

log "building native release APK (this can take a few minutes)..."
if ! "${REPO_ROOT}/scripts/flutter-cmd.sh" --in "$NATIVE_DIR" build apk --release --split-per-abi; then
  err "flutter build apk --release --split-per-abi failed"
  exit 2
fi

if [[ ! -f "$BUILT_APK" ]]; then
  err "expected arm64 APK not found at $BUILT_APK"
  exit 2
fi

log "publishing to ${PUBLIC_DIR}/ as ${STAMPED} + ${STABLE}"
cp "$BUILT_APK" "${PUBLIC_DIR}/${STAMPED}"
cp "$BUILT_APK" "${PUBLIC_DIR}/${STABLE}"

log "generating stable install landing page (public/native.html)"
"${REPO_ROOT}/scripts/gen-apk-install-page.sh" "$TS" "$STABLE" "$STAMPED" "$BUILD_COMMIT"

# Publish into the PERSISTENT bind-mounted native-dist (#700) — NOT docker cp into
# /app/public (which a recreate or public hot-push wipes). The container sees these
# immediately via the /app/native-dist mount, and they survive restarts.
log "publishing APKs + install page into ${NATIVE_DIST_HOST}/ (persistent, live-served)"
mkdir -p "$NATIVE_DIST_HOST"
cp "${PUBLIC_DIR}/${STAMPED}" "${NATIVE_DIST_HOST}/${STAMPED}"
cp "${PUBLIC_DIR}/${STABLE}" "${NATIVE_DIST_HOST}/${STABLE}"
cp "${PUBLIC_DIR}/native.html" "${NATIVE_DIST_HOST}/native.html"
cp "${PUBLIC_DIR}/native-time.js" "${NATIVE_DIST_HOST}/native-time.js"
cp "${PUBLIC_DIR}/native-feedback.js" "${NATIVE_DIST_HOST}/native-feedback.js"

# Fallback splits for non-arm64 devices (best-effort; published but not the
# primary install link). The server's native-dist regex serves these names too.
STAMPED_V7A="mobissh-native-${TS}-armeabi-v7a.apk"
STAMPED_X64="mobissh-native-${TS}-x86_64.apk"
if [[ -f "$FALLBACK_V7A" ]]; then
  cp "$FALLBACK_V7A" "${NATIVE_DIST_HOST}/${STAMPED_V7A}"
fi
if [[ -f "$FALLBACK_X64" ]]; then
  cp "$FALLBACK_X64" "${NATIVE_DIST_HOST}/${STAMPED_X64}"
fi

echo "+ PUBLISHED"
echo "+ install page (bookmark this, refresh for latest):"
echo "  ${SERVE_HOST}/native.html"
echo "+ stable apk:  ${SERVE_HOST}/${STABLE}"
echo "+ this build:  ${SERVE_HOST}/${STAMPED}"

# ntfy push (best-effort; no-op until ~/.mobissh/ntfy.env is set) — one-tap download.
# Lead with the version; body is the timestamped artifact (informative, not obvious).
NTFY_VERSION="$(grep -E '^version:' "${NATIVE_DIR}/pubspec.yaml" | awk '{print $2}' || true)"
"${REPO_ROOT}/scripts/notify-ntfy.sh" "MobiSSH ${NTFY_VERSION}" "${SERVE_HOST}/${STAMPED}" "${STAMPED}"
