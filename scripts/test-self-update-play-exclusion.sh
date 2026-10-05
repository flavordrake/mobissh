#!/usr/bin/env bash
# scripts/test-self-update-play-exclusion.sh — A6 (#1216, spec R13) on BUILT
# artifacts. Builds the Play App Bundle and a sideload release APK from this
# checkout and asserts:
#   AAB (Play)      has NO REQUEST_INSTALL_PACKAGES and NO updater provider
#   APK (sideload)  HAS both (positive control: the overlay is bundle-only)
# The mechanism under test is build.gradle.kts `isPlayBundle` + the
# tools:node="remove" overlay in android/app/src/play/AndroidManifest.xml.
#
# Slow (two release builds), so it is NOT in the fast gate; the fast gate pins
# the wiring (test/platform/self_update_manifest_test.dart). Run it after any
# change to the manifests or the gradle sourceSets block.
#
# Signing: uses whatever key.properties resolves to; without one the builds
# are unsigned (#1277), which does not affect the manifest under test.
# Exit 0 = both assertions hold. 1 = assertion failed. 2 = build failed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NATIVE_DIR="${REPO_ROOT}/native"
MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"
LOGFILE="${MOBISSH_LOGDIR}/test-self-update-play-exclusion.log"
exec > >(tee -a "$LOGFILE") 2>&1

SDK=""
for c in "${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}" /opt/android-sdk; do
  if [[ -n "$c" && -d "${c}/build-tools" ]]; then SDK="$c"; break; fi
done
AAPT2="$(ls -d "${SDK}"/build-tools/* | sort -V | tail -n 1)/aapt2"

PERM="android.permission.REQUEST_INSTALL_PACKAGES"
PROVIDER="UpdatesFileProvider"
AUTHORITY="updates.fileprovider"
FAIL=0

echo "> building the Play App Bundle (bundleRelease)"
if ! "${REPO_ROOT}/scripts/flutter-cmd.sh" --in "$NATIVE_DIR" build appbundle --release; then
  echo "! appbundle build failed"
  exit 2
fi
AAB="${NATIVE_DIR}/build/app/outputs/bundle/release/app-release.aab"
# The bundle's manifest is protobuf; its string values are plain UTF-8, so a
# byte grep is exact for these literal names.
AAB_MANIFEST="${MOBISSH_TMPDIR}/self-update-aab-manifest.pb"
unzip -p "$AAB" base/manifest/AndroidManifest.xml >"$AAB_MANIFEST"
for needle in "$PERM" "$PROVIDER" "$AUTHORITY"; do
  if grep -aq "$needle" "$AAB_MANIFEST"; then
    echo "! FAIL: AAB manifest contains ${needle} (R13)"
    FAIL=1
  else
    echo "+ AAB manifest has no ${needle}"
  fi
done

echo "> building the sideload release APK (assembleRelease, arm64)"
if ! "${REPO_ROOT}/scripts/flutter-cmd.sh" --in "$NATIVE_DIR" build apk --release --split-per-abi --target-platform android-arm64; then
  echo "! apk build failed"
  exit 2
fi
APK="${NATIVE_DIR}/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"
APK_MANIFEST="${MOBISSH_TMPDIR}/self-update-apk-manifest.txt"
"$AAPT2" dump xmltree --file AndroidManifest.xml "$APK" >"$APK_MANIFEST"
for needle in "$PERM" "$PROVIDER" "$AUTHORITY"; do
  if grep -q "$needle" "$APK_MANIFEST"; then
    echo "+ sideload APK manifest has ${needle}"
  else
    echo "! FAIL: sideload APK manifest lacks ${needle} (the updater would be dead)"
    FAIL=1
  fi
done

if [[ "$FAIL" -ne 0 ]]; then
  echo "! A6 FAILED — see ${LOGFILE}"
  exit 1
fi
echo "+ A6 PASS: Play bundle excludes the updater; sideload APK carries it"
