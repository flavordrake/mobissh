#!/usr/bin/env bash
# scripts/flutter-cmd.sh — Flutter CLI wrapper for the native rewrite (#501)
#
# The fd-dev container has /home/dev/.config owned by root, so Flutter's
# default XDG path fails on first run. This wrapper sets XDG_CONFIG_HOME to
# /home/dev/.flutter-config (user-writable) and invokes the SDK at
# /home/dev/flutter/bin/flutter. Use this wrapper for all Flutter calls until
# we either chown /home/dev/.config or move to a per-user dev container.

set -euo pipefail

FLUTTER_HOME="${FLUTTER_HOME:-/home/dev/flutter}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/home/dev/.flutter-config}"
export PATH="${FLUTTER_HOME}/bin:${PATH}"

mkdir -p "$XDG_CONFIG_HOME"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # resolve before any cd

# Optional --in <dir>: cd to that dir before invoking flutter. Avoids the
# `cd native && flutter ...` chain pattern in caller scripts.
WORKDIR=""
if [ "${1:-}" = "--in" ]; then
  WORKDIR="$2"
  shift 2
  cd "$WORKDIR"
fi

# Every APK/test build writes ~100M+ (2026-09-13: / hit 100% mid-gate). This is
# the one choke point all builds pass through, so the disk preflight lives here.
case "${1:-}" in
  build|test|run|drive)
    source "${SCRIPT_DIR}/lib/disk-guard.sh"
    disk_guard "flutter ${1}" ;;
esac

exec flutter "$@"
