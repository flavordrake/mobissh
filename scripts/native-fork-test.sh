#!/usr/bin/env bash
# scripts/native-fork-test.sh — run the vendored flterm fork's OWN test suite.
#
# The fork (native/third_party/flterm) is consumed by the native app via a
# `path:` dependency and declares `resolution: workspace` in its pubspec. The
# native app does not declare a `workspace:` member list, so the fork cannot be
# resolved standalone (`flutter test` from the fork dir exits 66: "found no
# workspace root"). This wrapper temporarily neutralises `resolution: workspace`
# in the fork pubspec, runs `flutter pub get` + `flutter test` INSIDE the fork,
# then ALWAYS restores the pubspec (and the lockfile) on exit — so the fork's
# unit/widget tests (structured_text, anchor_geometry, highlight, controller
# detection, selection, etc.) run on every dev/gate pass without polluting the
# committed tree.
#
# Usage:
#   scripts/native-fork-test.sh                 # full fork suite
#   scripts/native-fork-test.sh test/foo_test.dart [test/bar_test.dart ...]
# Extra args after any test paths are passed through to `flutter test`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_LOGDIR"
LOGFILE="${MOBISSH_LOGDIR}/native-fork-test.log"
exec > >(tee -a "$LOGFILE") 2>&1

FORK_DIR="${REPO_ROOT}/native/third_party/flterm"
LOCK="${FORK_DIR}/pubspec.lock"
LOCK_EXISTED=0
[ -f "$LOCK" ] && LOCK_EXISTED=1

# The fork's own pubspec AND its example/ pubspec both declare
# `resolution: workspace`; pub discovers the example while resolving, so BOTH
# must be neutralised for a standalone run.
PUBSPECS=(
  "${FORK_DIR}/pubspec.yaml"
  "${FORK_DIR}/example/pubspec.yaml"
)

restore() {
  for p in "${PUBSPECS[@]}"; do
    if [ -f "${p}.forktest.bak" ]; then
      mv -f "${p}.forktest.bak" "$p"
    fi
  done
  # The standalone `pub get` writes a fork-local lockfile that isn't part of the
  # workspace setup; drop it if it didn't exist before so the tree stays clean.
  if [ "$LOCK_EXISTED" -eq 0 ] && [ -f "$LOCK" ]; then
    rm -f "$LOCK"
  fi
  # Resolving the fork pulls the example/ package's deps too, which scatters
  # generated build artifacts (build/, example/pubspec.lock, generated Android/
  # iOS/macOS files). None belong in git — clean them so the tree stays pristine.
  rm -rf "${FORK_DIR}/build" "${FORK_DIR}/example/pubspec.lock"
  rm -rf "${FORK_DIR}/example/build" \
    "${FORK_DIR}/example/.dart_tool" \
    "${FORK_DIR}/example/android/local.properties" \
    "${FORK_DIR}/example/android/app/src/main/java" \
    "${FORK_DIR}/example/ios/Flutter/Generated.xcconfig" \
    "${FORK_DIR}/example/ios/Flutter/ephemeral" \
    "${FORK_DIR}/example/ios/Flutter/flutter_export_environment.sh" \
    "${FORK_DIR}/example/ios/Runner/GeneratedPluginRegistrant.h" \
    "${FORK_DIR}/example/ios/Runner/GeneratedPluginRegistrant.m" \
    "${FORK_DIR}/example/macos/Flutter/ephemeral"
}
trap restore EXIT

# Neutralise `resolution: workspace` so the fork resolves on its own.
for p in "${PUBSPECS[@]}"; do
  [ -f "$p" ] || continue
  cp "$p" "${p}.forktest.bak"
  sed -i 's/^resolution: workspace/# resolution: workspace (disabled by native-fork-test.sh)/' "$p"
done

echo "> fork: flutter pub get..."
"${REPO_ROOT}/scripts/flutter-cmd.sh" --in "$FORK_DIR" pub get

echo "> fork: flutter test ${*:-(full suite)}..."
"${REPO_ROOT}/scripts/flutter-cmd.sh" --in "$FORK_DIR" test "$@"

echo "+ FORK TESTS PASSED"
