#!/usr/bin/env bash
# scripts/build-release-aab.sh — build a SIGNED release Android App Bundle (.aab)
# for Play Store upload (#966).
#
# WHY separate from ship-native.sh: ship-native builds --split-per-abi APKs for
# tailnet SIDELOAD. The Play Store takes an App BUNDLE (.aab) — Play generates
# per-device APKs on download. This is that build.
#
# Signing: the release build uses the signingConfig in app/build.gradle.kts,
# which loads the keystore from key.properties (MOBISSH_KEY_PROPERTIES or the
# default ~/.mobissh-android/key.properties). If that config is MISSING, gradle
# falls back to the DEBUG keystore and Play would reject the upload — so this
# script FAILS LOUDLY rather than emit a debug-signed bundle.
#
# Play requires a MONOTONIC versionCode per upload. This builds at the CURRENT
# pubspec version (does NOT auto-bump — store versioning is deliberate). Bump the
# pubspec `+N` build number before each subsequent AAB.
#
# Usage: scripts/build-release-aab.sh
# Exit 0 = signed AAB written. Exit 1 = build failure. Exit 2 = missing keystore.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NATIVE_DIR="${REPO_ROOT}/native"
MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"
LOGFILE="${MOBISSH_LOGDIR}/build-release-aab.log"
exec > >(tee -a "$LOGFILE") 2>&1

KEY_PROPS="${MOBISSH_KEY_PROPERTIES:-/home/dev/.mobissh-android/key.properties}"
if [ ! -f "$KEY_PROPS" ]; then
  echo "! FATAL: release keystore config missing ($KEY_PROPS)."
  echo "  Without it the AAB is DEBUG-signed and Play rejects it. Aborting."
  exit 2
fi
echo "> release keystore config: $KEY_PROPS"

VERSION="$(grep -m1 '^version:' "${NATIVE_DIR}/pubspec.yaml" | awk '{print $2}')"
echo "> building SIGNED release App Bundle for $VERSION"

# Pin to the BUILD cores (off the emulator's reserved cores) so a live emulator
# isn't starved (same rationale as ship-native / native-connect-test).
BUILD_CORES="${BUILD_CORES:-3-11}"
TASKSET=()
if command -v taskset >/dev/null 2>&1; then TASKSET=(taskset -c "$BUILD_CORES"); fi

# Full multi-ABI bundle (Play splits per device). R8/minify runs (release type).
if ! "${TASKSET[@]}" "${REPO_ROOT}/scripts/flutter-cmd.sh" --in "$NATIVE_DIR" \
    build appbundle --release; then
  echo "! AAB build FAILED — see $LOGFILE"
  exit 1
fi

SRC="${NATIVE_DIR}/build/app/outputs/bundle/release/app-release.aab"
if [ ! -f "$SRC" ]; then
  echo "! expected bundle not found at $SRC"
  exit 1
fi

STAMP="$(date +%Y%m%dT%H%M%S%z)"
# Publish into the PERSISTENT bind-mounted native-dist (#700) so the running
# prod container serves it (server allowlists mobissh-*.aab, #966): a versioned
# copy for the record + a stable `mobissh-release.aab` alias for a clean URL.
NATIVE_DIST="${NATIVE_DIST_HOST:-${REPO_ROOT}/native-dist}"
SERVE_HOST="${SERVE_HOST:-https://mobissh.tailbe5094.ts.net}"
mkdir -p "$NATIVE_DIST"
VERSIONED="${NATIVE_DIST}/mobissh-${VERSION}-${STAMP}.aab"
STABLE="${NATIVE_DIST}/mobissh-release.aab"
cp "$SRC" "$VERSIONED"
cp "$SRC" "$STABLE"

echo "+ AAB BUILT (signed with the release keystore) + PUBLISHED"
echo "  versioned: $VERSIONED"
echo "  size: $(du -h "$STABLE" | cut -f1)  version: $VERSION"
echo "  stable download (bookmark): ${SERVE_HOST}/mobissh-release.aab"
echo "  this build:                 ${SERVE_HOST}/mobissh-${VERSION}-${STAMP}.aab"
echo
echo "  Upload to Play Console → Internal testing. Play requires a MONOTONIC"
echo "  versionCode — bump pubspec (+N) before the next AAB."
