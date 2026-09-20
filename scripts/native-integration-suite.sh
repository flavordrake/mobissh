#!/usr/bin/env bash
# scripts/native-integration-suite.sh — Run the FULL on-emulator integration
# suite as a real merge/release gate (#589).
#
# WHY THIS EXISTS: the fast gate (native-fast-gate.sh) runs
# `flutter test --exclude-tags integration` — so the byte-flow / state-machine /
# lifecycle tests in native/integration_test/ EXIST but never run automatically.
# That is the root cause of the project's recurring "shipped green, broke on
# device" pattern (#539/#546/#547, #590 stale-shell, etc.). This script makes
# the existing suite actually gate.
#
# It runs each integration test on a booted emulator through the proven
# socat+adb-reverse bridge (delegating to native-connect-test.sh, which owns the
# bridge lifecycle + POST_NOTIFICATIONS grant-watcher). The multi-session
# lifecycle test additionally needs a SECOND bridge port, supplied here.
#
# NEVER SILENTLY SKIPS: if there's no emulator / no KVM, it exits non-zero with
# a loud "NOT VALIDATED" so an absent emulator can't masquerade as a pass — the
# whole point of #589.
#
# Usage: scripts/native-integration-suite.sh [--allow-no-emulator]
#   --allow-no-emulator   downgrade the missing-emulator failure to a skip
#                         (exit 0) — for environments that genuinely can't run
#                         an AVD (CI without KVM). Use sparingly; the default is
#                         to FAIL so local/release runs can't skip silently.
#
# Exit 0 = all integration tests passed (or explicitly-allowed skip).
# Exit 1 = a test failed. Exit 2 = setup error / emulator missing (not allowed).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"
LOGFILE="${MOBISSH_LOGDIR}/native-integration-suite.log"
exec > >(tee -a "$LOGFILE") 2>&1

ALLOW_NO_EMULATOR=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-no-emulator) ALLOW_NO_EMULATOR=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "! unknown option: $1" >&2; exit 2 ;;
  esac
done

NATIVE_DIR="${REPO_ROOT}/native"

log() { echo "> $*"; }
err() { echo "! $*" >&2; }

# What each test needs from the runner is DERIVED FROM THE TEST SOURCE, not
# listed here (#1101 G1-G3). Two hand-maintained copies of `needs_second_bridge()`
# lived in this script and integration-subset.sh; both drifted from the tests that
# declare the requirement in their own headers, and two tests failed for a HARNESS
# reason that read exactly like a product regression. See the library header.
INTEGRATION_REPO_ROOT="$REPO_ROOT"
source "${REPO_ROOT}/scripts/lib/integration-fixtures.sh"

# Emulator guard — the #589 contract: an absent emulator must be LOUD, never a
# silent pass. A LEASED fleet device (with-fleet-emulator.sh exports
# EMU_ADBD_ENDPOINT + EMU_ENSURE=0) is only in `adb devices` after a connect —
# native-connect-test.sh does that per test, but this guard runs first.
if [[ -n "${EMU_ADBD_ENDPOINT:-}" && "${EMU_ENSURE:-1}" == "0" ]]; then
  log "adb connect ${EMU_ADBD_ENDPOINT} (leased fleet emulator)"
  adb connect "$EMU_ADBD_ENDPOINT" || true
fi
DEVICE="$(adb devices 2>/dev/null | awk 'NR>1 && $2=="device" {print $1; exit}' || true)"
if [[ -z "$DEVICE" ]]; then
  if [[ "$ALLOW_NO_EMULATOR" -eq 1 ]]; then
    echo "! INTEGRATION SUITE NOT VALIDATED — no emulator (explicitly allowed)"
    echo "  These transition/byte-flow tests did NOT run. Do not treat as a pass."
    exit 0
  fi
  err "INTEGRATION SUITE NOT VALIDATED — no online emulator"
  err "Boot one (scripts/setup-avd.sh) or pass --allow-no-emulator to skip loudly."
  exit 2
fi
log "device: $DEVICE"

# Discover the suite from disk so a newly-added integration test is gated
# automatically (no hand-maintained list to drift).
mapfile -t TESTS < <(find "${NATIVE_DIR}/integration_test" -maxdepth 1 -name '*_test.dart' | sort)
if [[ "${#TESTS[@]}" -eq 0 ]]; then
  err "no integration tests found under native/integration_test/"
  exit 2
fi
log "discovered ${#TESTS[@]} integration tests"

# One CURRENT, unambiguous sshd for the whole run (#1101 G0). Pinning it here
# rather than per-test also keeps native-connect-test.sh from spawning and then
# tearing down a fixture around every single test — the cc_* setup scripts seed
# state on it that must still be there when the test connects.
integration_pin_fixture

PASS=()
FAIL=()
SKIP=()

for abs in "${TESTS[@]}"; do
  rel="integration_test/$(basename "$abs")"

  # G2: a test that declares its OWN runner is not this suite's to run.
  own_runner="$(integration_declared_runner "$abs")"
  if [[ -n "$own_runner" ]]; then
    log "=== skipping $rel — not an Android device test; its runner is: $own_runner"
    SKIP+=("$rel → $own_runner")
    continue
  fi

  log "=== running $rel ==="
  # Bridge, jump target, and the declared setup/teardown bracket all live in
  # scripts/lib/integration-fixtures.sh so this runner and integration-subset.sh
  # cannot wire the same test up two different ways (#1101 G1/G3).
  if integration_run_one "$rel"; then PASS+=("$rel"); else FAIL+=("$rel"); fi
done

echo "> INTEGRATION SUITE RESULT: ${#PASS[@]} passed, ${#FAIL[@]} failed, ${#SKIP[@]} run elsewhere (of ${#TESTS[@]})"
for t in "${PASS[@]}"; do echo "  + $t"; done
for t in "${FAIL[@]}"; do echo "  ! $t"; done
for t in "${SKIP[@]:-}"; do [[ -n "$t" ]] && echo "  ~ $t"; done

if [[ "${#FAIL[@]}" -gt 0 ]]; then
  echo "! NATIVE INTEGRATION SUITE FAILED"
  exit 1
fi
echo "+ NATIVE INTEGRATION SUITE PASSED"
