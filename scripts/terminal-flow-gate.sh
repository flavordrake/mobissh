#!/usr/bin/env bash
# scripts/terminal-flow-gate.sh — the TERMINAL-FLOW gate (owner directive
# 2026-07-01): run the saga-critical end-to-end flows on the emulator.
#
# WHY: the full #589 integration suite (native-integration-suite.sh, ~47 tests)
# is too slow to run per-ship, and the fast gate excludes integration tests
# entirely — so the connect→tmux→TUI→scroll→copy flow kept breaking in new
# ways (the +94 long-press pivot silently broke gutter_copy_scrollback_test;
# nobody ran it until 2026-07-01). This is the MIDDLE tier: two files, ~10-15
# minutes, REQUIRED before shipping any change that touches:
#   - terminal view / gesture routing / selection / gutter (ghostty_*.dart,
#     gutter_*.dart)
#   - the copy path (visibleRowsText, clipboard, massager)
#   - the flterm fork (native/third_party/flterm/)
#   - detection / anchors / marks
#
# Delegates to native-connect-test.sh (owns emulator ensure + socat bridge +
# permission watcher). Never silently skips — same #589 contract as the full
# suite.
#
# Usage: scripts/terminal-flow-gate.sh
# Exit 0 = both flows green. Exit 1 = a flow failed. Exit 2 = setup error.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"
LOGFILE="${MOBISSH_LOGDIR}/terminal-flow-gate.log"
exec > >(tee -a "$LOGFILE") 2>&1

CONNECT_TEST="${REPO_ROOT}/scripts/native-connect-test.sh"

# The saga-critical flows, in dependency order:
#   golden_flow_tui_test — connect → tmux → TUI screen → detection renders
#     (anchors AND the gutter-mark widget, the #958 class) → scroll → verbatim
#     gutter copy (interior spaces +98 class; visible-not-tail #962 class).
#   gutter_copy_scrollback_test — the #962 deep repro: MAIN vs ALT screen,
#     scrolled-back copy, immediate-after-scroll timing.
FLOWS=(
  integration_test/golden_flow_tui_test.dart
  integration_test/gutter_copy_scrollback_test.dart
  integration_test/wrap_join_copy_test.dart
  integration_test/tui_wrap_join_copy_test.dart
  integration_test/detect_paint_freeze_test.dart
)

PASS=()
FAIL=()
for rel in "${FLOWS[@]}"; do
  echo "> terminal-flow: running $rel"
  if "$CONNECT_TEST" "$rel"; then
    PASS+=("$rel")
  else
    FAIL+=("$rel")
  fi
done

echo "> TERMINAL FLOW GATE: ${#PASS[@]} passed, ${#FAIL[@]} failed (of ${#FLOWS[@]})"
for t in "${PASS[@]}"; do echo "  + $t"; done
for t in "${FAIL[@]}"; do echo "  ! $t"; done

if [[ "${#FAIL[@]}" -gt 0 ]]; then
  echo "! TERMINAL FLOW GATE FAILED — do NOT ship terminal/gesture/copy changes"
  exit 1
fi
echo "+ TERMINAL FLOW GATE PASSED"
