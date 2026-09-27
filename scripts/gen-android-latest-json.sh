#!/usr/bin/env bash
# scripts/gen-android-latest-json.sh DIST_DIR STAMPED_APK VERSION SERVE_HOST [NOTES]
#
# Writes DIST_DIR/android-latest.json, the self-update manifest the sideloaded
# app polls (#1215, contract pinned in docs/self-update.md). Split out of
# native-release-apk.sh so the contract is testable without a release build
# (test/infra/self-update-publish.test.js).
#
# The sha256 is taken from DIST_DIR/STAMPED_APK, the exact file that is served,
# and the script refuses when that file is absent: the manifest can only ever
# name an APK already in place. It is written to a temp file in DIST_DIR and
# renamed over the old one, so a reader never sees a partial manifest.
#
# VERSION is the full pubspec string x.y.z[-STAGE]+B; `build` is B as an integer.
# NOTES: only its first line is kept (may be empty).
set -euo pipefail

if [[ "$#" -lt 4 || "$#" -gt 5 ]]; then
  echo "! usage: $0 DIST_DIR STAMPED_APK VERSION SERVE_HOST [NOTES]" >&2
  exit 2
fi
DIST="$1"; STAMPED="$2"; VERSION="$3"; SERVE_HOST="${4%/}"; NOTES="${5:-}"

APK="${DIST}/${STAMPED}"
if [[ ! -f "$APK" ]]; then
  echo "! gen-android-latest-json: ${APK} is not published; refusing to name it" >&2
  exit 2
fi
if [[ "$SERVE_HOST" != https://* ]]; then
  echo "! gen-android-latest-json: serve host must be https: ${SERVE_HOST}" >&2
  exit 2
fi
if [[ "$VERSION" != *+* || ! "${VERSION##*+}" =~ ^[0-9]+$ ]]; then
  echo "! gen-android-latest-json: version has no integer build ordinal: ${VERSION}" >&2
  exit 2
fi
BUILD="${VERSION##*+}"

SHA="$(sha256sum "$APK")"
SHA="${SHA%% *}"
if [[ ! "$SHA" =~ ^[0-9a-f]{64}$ ]]; then
  echo "! gen-android-latest-json: bad sha256 for ${APK}" >&2
  exit 2
fi

NOTES="${NOTES%%$'\n'*}"
BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

TMP="$(mktemp "${DIST}/.android-latest.json.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
jq -n \
  --arg version "$VERSION" \
  --argjson build "$BUILD" \
  --arg url "${SERVE_HOST}/${STAMPED}" \
  --arg sha256 "$SHA" \
  --arg builtAt "$BUILT_AT" \
  --arg notes "$NOTES" \
  '{version: $version, build: $build, abi: "arm64-v8a", url: $url, sha256: $sha256, builtAt: $builtAt, notes: $notes}' \
  > "$TMP"
chmod 644 "$TMP"
mv -f "$TMP" "${DIST}/android-latest.json"
trap - EXIT
echo "> android-latest.json: build ${BUILD} -> ${SERVE_HOST}/${STAMPED}"
