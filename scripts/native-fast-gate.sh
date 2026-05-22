#!/usr/bin/env bash
# scripts/native-fast-gate.sh — Pre-commit gate for the native rewrite (#501)
#
# Mirrors scripts/test-fast-gate.sh's role for the Flutter project at native/.
# Runs analyzer + unit tests. Does NOT build an APK — that's a slower gate
# that container-ctl-equivalent will run later.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_LOGDIR"
LOGFILE="${MOBISSH_LOGDIR}/native-fast-gate.log"
exec > >(tee -a "$LOGFILE") 2>&1

NATIVE_DIR="${REPO_ROOT}/native"

echo "> Gate 1/2: flutter analyze..."
if "${REPO_ROOT}/scripts/flutter-cmd.sh" --in "$NATIVE_DIR" analyze; then
  echo "+ analyze: pass"
else
  echo "! analyze: FAIL"
  exit 1
fi

echo "> Gate 2/2: flutter test (excluding integration tag)..."
if "${REPO_ROOT}/scripts/flutter-cmd.sh" --in "$NATIVE_DIR" test \
    --exclude-tags integration; then
  echo "+ test: pass"
else
  echo "! test: FAIL"
  exit 1
fi

echo "+ NATIVE FAST GATE PASSED"
