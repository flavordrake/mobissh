#!/usr/bin/env bash
# scripts/validate-cc-parser.sh — the #907 validation spike runner.
#
# Captures a FRESH tmux -CC protocol sample from a throwaway session (via
# scripts/capture-tmux-cc.sh) together with tmux's INDEPENDENT list-windows
# truth, then runs the Dart spike (native/tool/validate_cc_parser.dart) which
# feeds the stream through TmuxControlParser and asserts the parser's parsed
# geometry/active-window EQUALS tmux's truth. Exit 0 == parser view == reality.
#
# This proves Part A's premise before any session-layer rewrite (Parts B/C).
#
# Usage: scripts/validate-cc-parser.sh [--no-recapture]
#   --no-recapture   skip the live tmux capture; validate the committed fixture.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NATIVE_DIR="${REPO_ROOT}/native"
FIXTURE_DIR="${NATIVE_DIR}/test/fixtures/tmux_cc"

RECAPTURE=1
if [[ "${1:-}" == "--no-recapture" ]]; then
  RECAPTURE=0
fi

if [[ "$RECAPTURE" -eq 1 ]]; then
  echo "> capturing a fresh tmux -CC sample (throwaway session)..."
  "${REPO_ROOT}/scripts/capture-tmux-cc.sh" "$FIXTURE_DIR"
fi

echo "> running the parser parity spike..."
"${REPO_ROOT}/scripts/flutter-cmd.sh" --in "$NATIVE_DIR" \
  pub run tool/validate_cc_parser.dart \
  test/fixtures/tmux_cc/capture.cc test/fixtures/tmux_cc/truth-windows.txt
