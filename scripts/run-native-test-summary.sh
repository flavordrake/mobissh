#!/usr/bin/env bash
set -euo pipefail

# Run the native unit/widget suite and print ONLY the failures + final tally.
# Avoids the streaming-output truncation that hides the summary line.

LOGDIR="/tmp/mobissh"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/native-test-summary-$(date +%Y%m%dT%H%M%S%z).log"

SCRIPTDIR="$(cd "$(dirname "$0")" && pwd)"

set +e
"$SCRIPTDIR/flutter-cmd.sh" --in native test --exclude-tags integration --reporter expanded >"$LOGFILE" 2>&1
code=$?
set -e

echo "exit_code=$code"
echo "--- failures (if any) ---"
grep -nE '\[E\]|: Some tests failed|Failed to load|EXCEPTION|\bfailed\b' "$LOGFILE" || echo "(no failure lines matched)"
echo "--- tail ---"
tail -n 15 "$LOGFILE"
