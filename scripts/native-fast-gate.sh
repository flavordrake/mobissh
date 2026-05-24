#!/usr/bin/env bash
# scripts/native-fast-gate.sh — Pre-commit gate for the native rewrite (#501)
#
# Mirrors scripts/test-fast-gate.sh's role for the Flutter project at native/.
# Runs analyzer + unit tests. Does NOT build an APK — that's a slower gate
# that container-ctl-equivalent will run later.
#
# Usage: scripts/native-fast-gate.sh [--with-acceptance]
#   --with-acceptance   tail an install + first-run smoke against the APK at
#                       public/mobissh-native.apk on an online emulator. Opt-in
#                       because it needs a running AVD; not safe to require on
#                       every commit.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_LOGDIR"
LOGFILE="${MOBISSH_LOGDIR}/native-fast-gate.log"
exec > >(tee -a "$LOGFILE") 2>&1

WITH_ACCEPTANCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-acceptance) WITH_ACCEPTANCE=1; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "! unknown option: $1" >&2; exit 2 ;;
  esac
done

NATIVE_DIR="${REPO_ROOT}/native"
TOTAL_GATES=$(( WITH_ACCEPTANCE == 1 ? 3 : 2 ))

echo "> Gate 1/${TOTAL_GATES}: flutter analyze..."
if "${REPO_ROOT}/scripts/flutter-cmd.sh" --in "$NATIVE_DIR" analyze; then
  echo "+ analyze: pass"
else
  echo "! analyze: FAIL"
  exit 1
fi

echo "> Gate 2/${TOTAL_GATES}: flutter test (excluding integration tag)..."
if "${REPO_ROOT}/scripts/flutter-cmd.sh" --in "$NATIVE_DIR" test \
    --exclude-tags integration; then
  echo "+ test: pass"
else
  echo "! test: FAIL"
  exit 1
fi

if [[ "$WITH_ACCEPTANCE" -eq 1 ]]; then
  echo "> Gate 3/3: native acceptance (install + first-run on emulator)..."
  if "${REPO_ROOT}/scripts/native-acceptance.sh"; then
    echo "+ acceptance: pass"
  else
    echo "! acceptance: FAIL"
    exit 1
  fi
else
  echo "  (acceptance gate skipped — rerun with --with-acceptance to include it)"
fi

echo "+ NATIVE FAST GATE PASSED"
