#!/usr/bin/env bash
# scripts/integration-failure-signatures.sh — one-line failure SIGNATURE per red
# test for two runs in the native integration suite log, so a candidate run can
# be diffed against a baseline by CAUSE (Expected/Actual/message) instead of by
# test name. Same name + different signature = a different failure.
#
# Usage:
#   scripts/integration-failure-signatures.sh BASE_START BASE_END CAND_START CAND_END [LOG]
# Line numbers come from `grep -n "INTEGRATION SUITE RESULT" $LOG` — a run spans
# from the line after the previous RESULT to its own RESULT line.
set -euo pipefail

if [[ $# -lt 4 ]]; then
  echo "Usage: $0 BASE_START BASE_END CAND_START CAND_END [LOG]" >&2
  exit 2
fi
LOG="${5:-${MOBISSH_LOGDIR:-/tmp/mobissh/logs}/native-integration-suite.log}"

sig_run() {
  local label="$1" start="$2" end="$3"
  awk -v s="$start" -v e="$end" -v label="$label" '
    NR<s || NR>e { next }
    /^> === running integration_test\// {
      if (test!="" && sig!="") printf "%s %-42s %s\n", label, test, sig
      test=$4; sig=""; grab=0; next
    }
    sig=="" && /The following TestFailure was thrown/ { grab=4; next }
    grab>0 { sub(/^[ \t]+/,""); sig=sig " | " $0; grab--; next }
    sig=="" && /did not complete \[E\]|no online device|TimeoutException|Bad state|RangeError|Null check|Exception: / { sig=$0 }
    END { if (test!="" && sig!="") printf "%s %-42s %s\n", label, test, sig }
  ' "$LOG"
}

sig_run BASE "$1" "$2"
sig_run CAND "$3" "$4"
