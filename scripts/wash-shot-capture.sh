#!/usr/bin/env bash
# scripts/wash-shot-capture.sh — watch a running #1067 shot-test log and grab
# emulator screenshots while each *_WINDOW_OPEN hold window is on screen.
#
# The integration test (wash_live_tracking_1067_shot_test.dart) logs
# WASH1067_<PHASE>_WINDOW_OPEN then holds the frame for several seconds. This
# tails the log and, on each OPEN marker, fires scripts/emu-shot.sh a few times
# across the window so at least one lands mid-motion. Each screenshot path is
# echoed (one line = one event) so a Monitor surfaces it. Exits when the settled
# window closes or the log ends.
#
# Usage: scripts/wash-shot-capture.sh <test-log-path>
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="${1:?usage: wash-shot-capture.sh <test-log-path>}"

capture_window() {
  local label="$1"
  local n=3
  for ((i = 1; i <= n; i++)); do
    if path="$("${REPO_ROOT}/scripts/emu-shot.sh" "$label-$i" 2>/dev/null)"; then
      echo "SHOT $label-$i $path"
    else
      echo "SHOT-FAIL $label-$i"
    fi
    sleep 1.5
  done
}

# Wait for the log to exist.
for _ in $(seq 1 120); do
  [ -f "$LOG" ] && break
  sleep 1
done

tail -n +1 -f "$LOG" | while IFS= read -r line; do
  case "$line" in
    *WASH1067_MIDSCROLL_WINDOW_OPEN*) capture_window midscroll ;;
    *WASH1067_MIDCHURN_WINDOW_OPEN*) capture_window midchurn ;;
    *WASH1067_SETTLED_WINDOW_OPEN*)
      capture_window settled
      echo "DONE captured all windows"
      exit 0
      ;;
    *"All tests passed"*|*"Some tests failed"*)
      echo "TEST-ENDED before settled window"
      exit 0
      ;;
  esac
done
