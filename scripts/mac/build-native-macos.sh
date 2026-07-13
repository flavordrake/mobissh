#!/usr/bin/env bash
# scripts/mac/build-native-macos.sh — build + stage the macOS app bundle (#1026).
#
# Authored on fd-dev, EXECUTED ONLY on the runner Mac (matts-macbook-air) — the
# fleet's only host with Xcode. Mirrors the Android build half of the pipeline:
#   Android: scripts/native-release-apk.sh (build APK on fd-dev, publish here)
#   macOS  : THIS (build .app on the Mac, stage) -> fd-dev pulls + publishes via
#            scripts/publish-native-macos.sh (fd-dev owns native.html publishing).
#
# It does NOT publish or touch native.html — the Mac has no access to fd-dev's
# native-dist/. It builds, zips, and prints the exact `host:path` + digest fd-dev
# needs; the Mac session relays that to fd-dev on the bus (see the printed reply).
#
# HONEST STATUS: like the rest of scripts/mac/, this has never executed on a Mac.
# Validated by `bash -n` only. Expect first-contact fixes (Flutter output paths,
# bundle name, ditto flags) on the first real run.
#
# Prereqs (scripts/mac/README.md): full Xcode + license accepted, Flutter >= 3.44
# on PATH with `flutter config --enable-macos-desktop`, `flutter doctor` clean.
#
# Usage: scripts/mac/build-native-macos.sh
#   Env: STAGE_DIR (default ~/mobissh-native-dist) — where the zip is staged for
#        fd-dev to rsync-pull.
set -euo pipefail
cd "$(dirname "$0")/../.."          # repo root

STAGE_DIR="${STAGE_DIR:-$HOME/mobissh-native-dist}"
mkdir -p "$STAGE_DIR"

command -v flutter >/dev/null || { echo "! flutter not on PATH — see scripts/mac/README.md prereqs" >&2; exit 2; }

echo "> flutter pub get + build macos (release)"
( cd native && flutter pub get && flutter build macos --release )

APP_DIR="native/build/macos/Build/Products/Release"
APP="$(find "$APP_DIR" -maxdepth 1 -name '*.app' | head -1)"
if [ -z "$APP" ]; then
  echo "! no .app under ${APP_DIR} — did the build succeed?" >&2
  exit 2
fi

VERSION="$(grep -m1 '^version:' native/pubspec.yaml | sed 's/^version:[[:space:]]*//' | tr -d '[:space:]')"
[ -n "$VERSION" ] || VERSION="unknown"
STAMP="$(date +%Y%m%dT%H%M%S%z)"
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
ZIP="${STAGE_DIR}/mobissh-native-macos-${VERSION}-${STAMP}.zip"

echo "> packaging $(basename "$APP") -> ${ZIP}"
# ditto (not zip) so the .app's symlinks + bundle structure survive the archive.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
HOST="$(hostname -s)"

echo "+ BUILT macOS ${VERSION} (${STAMP}) commit ${COMMIT}"
echo "+ staged: ${ZIP}"
echo "+ sha256: ${SHA}"
echo
echo "Relay to fd-dev on the bus so it can pull + publish:"
echo "  hub send fd-dev-IT \"done: macOS build staged\" \"from ${HOST}:${ZIP} version ${VERSION} stamp ${STAMP} commit ${COMMIT} sha256 ${SHA}\""
echo
echo "fd-dev then publishes:"
echo "  scripts/publish-native-macos.sh --from ${HOST}:${ZIP} --version ${VERSION} --stamp ${STAMP} --commit ${COMMIT} --sha256 ${SHA}"
