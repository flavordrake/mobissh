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

# A subset run is only comparable to the suite if it wires each test up the SAME
# WAY. It used to mirror the suite by hand — two copies of needs_second_bridge(),
# both drifted from the tests that declare the requirement (#1101 G3). Now both
# runners derive the wiring from the test source through one shared library.
INTEGRATION_REPO_ROOT="$REPO_ROOT"
source "${REPO_ROOT}/scripts/lib/integration-fixtures.sh"

# One CURRENT, unambiguous sshd for the whole subset (#1101 G0) — same pinning
# the suite does, so a subset baseline means the same thing.
integration_pin_fixture

passed=()
failed=()
skipped=()
for t in "$@"; do
  own_runner="$(integration_declared_runner "$t")"
  if [[ -n "$own_runner" ]]; then
    log "=== skipping $t — not an Android device test; its runner is: $own_runner"
    skipped+=("$t → $own_runner")
    continue
  fi
  log "=== running $t ==="
  if integration_run_one "$t"; then
    passed+=("$t"); log "PASS $t"
  else
    failed+=("$t"); log "FAIL $t"
  fi
done

log "SUBSET RESULT: ${#passed[@]} passed, ${#failed[@]} failed, ${#skipped[@]} run elsewhere (of $#)"
for t in "${passed[@]:-}"; do [[ -n "$t" ]] && echo "  + $t"; done
for t in "${failed[@]:-}"; do [[ -n "$t" ]] && echo "  ! $t"; done
for t in "${skipped[@]:-}"; do [[ -n "$t" ]] && echo "  ~ $t"; done

[[ ${#failed[@]} -eq 0 ]]
