#!/usr/bin/env bash
# scripts/integration-subset.sh — run a NAMED SUBSET of integration tests over one
# emulator lease, instead of the full 82-test suite.
#
# Why: attributing an integration failure to a change requires a BASELINE — the
# same tests on main. Re-running all 82 to compare a handful of failures wastes
# ~40min of an EXCLUSIVE shared-device lease. This runs just the tests you name,
# sequentially, reusing the caller's lease/device env.
#
# Usage (inside a lease):
#   scripts/with-fleet-emulator.sh -- scripts/integration-subset.sh \
#     integration_test/sftp_browse_smoke_test.dart integration_test/…
#
# Exits 0 iff every named test passed. Prints a PASS/FAIL roster at the end.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_LOGDIR"

if [[ $# -eq 0 ]]; then
  echo "Usage: scripts/integration-subset.sh <integration_test/foo_test.dart>..." >&2
  exit 2
fi

log() { echo "> [subset] $*"; }

passed=()
failed=()
for t in "$@"; do
  log "=== running $t ==="
  if "${REPO_ROOT}/scripts/native-connect-test.sh" "$t"; then
    passed+=("$t")
    log "PASS $t"
  else
    failed+=("$t")
    log "FAIL $t"
  fi
done

log "SUBSET RESULT: ${#passed[@]} passed, ${#failed[@]} failed (of $#)"
for t in "${passed[@]:-}"; do [[ -n "$t" ]] && echo "  + $t"; done
for t in "${failed[@]:-}"; do [[ -n "$t" ]] && echo "  ! $t"; done

[[ ${#failed[@]} -eq 0 ]]
