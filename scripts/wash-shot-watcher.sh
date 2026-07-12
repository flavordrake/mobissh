#!/usr/bin/env bash
# scripts/wash-shot-watcher.sh — fire scripts/emu-shot.sh when an on-emulator
# acceptance test logs a "*_WINDOW_OPEN" marker, so the churn / settled hold gets
# a screenshot without hand-timing it. Reads the connect-test output file, grabs
# ONE shot per marker (labelled by the marker), and exits when the log ends or a
# SETTLED_WINDOW_CLOSED marker is seen.
#
# Usage: scripts/wash-shot-watcher.sh <connect-test-output-file>
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
LOGFILE="${1:?usage: wash-shot-watcher.sh <output-file>}"

# Wait for the file to exist (the connect-test may start a beat later).
for _ in $(seq 1 60); do
  [ -f "$LOGFILE" ] && break
  sleep 1
done

# Follow the log; on each *_WINDOW_OPEN grab a shot; stop at SETTLED close.
tail -n +1 -F "$LOGFILE" 2>/dev/null | while IFS= read -r line; do
  case "$line" in
    *_WINDOW_OPEN*)
      label="$(echo "$line" | grep -oE '[A-Z0-9_]+_WINDOW_OPEN' | head -1)"
      shot="$("$SELF_DIR/emu-shot.sh" "${label:-wash_window}" 2>/dev/null || true)"
      echo "wash-shot-watcher: ${label:-window} -> ${shot:-<no shot>}"
      ;;
    *SETTLED_WINDOW_CLOSED*)
      echo "wash-shot-watcher: settled window closed — done"
      exit 0
      ;;
  esac
done
