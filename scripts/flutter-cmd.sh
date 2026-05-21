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

# Optional --in <dir>: cd to that dir before invoking flutter. Avoids the
# `cd native && flutter ...` chain pattern in caller scripts.
WORKDIR=""
if [ "${1:-}" = "--in" ]; then
  WORKDIR="$2"
  shift 2
  cd "$WORKDIR"
fi

exec flutter "$@"
