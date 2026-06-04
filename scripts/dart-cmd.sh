#!/usr/bin/env bash
# scripts/dart-cmd.sh — Dart CLI wrapper for the native rewrite (#501)
#
# Mirror of flutter-cmd.sh for the `dart` tool (e.g. `dart format`). The fd-dev
# container has /home/dev/.config owned by root, so the default XDG path fails
# on first run. This wrapper sets XDG_CONFIG_HOME to a user-writable dir and
# invokes the SDK's bundled dart at /home/dev/flutter/bin/dart.

set -euo pipefail

FLUTTER_HOME="${FLUTTER_HOME:-/home/dev/flutter}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/home/dev/.flutter-config}"
export PATH="${FLUTTER_HOME}/bin:${PATH}"

mkdir -p "$XDG_CONFIG_HOME"

# Optional --in <dir>: cd to that dir before invoking dart.
if [ "${1:-}" = "--in" ]; then
  WORKDIR="$2"
  shift 2
  cd "$WORKDIR"
fi

exec dart "$@"
