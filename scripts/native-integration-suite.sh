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
CONNECT_TEST="${REPO_ROOT}/scripts/native-connect-test.sh"

log() { echo "> $*"; }
err() { echo "! $*" >&2; }

# Tests that need a SECOND distinct host:port tuple on-device (two real
# sessions). native-connect-test.sh wires the 2nd bridge when BRIDGE_PORT2 is
# exported.
needs_second_bridge() {
  case "$1" in
    *multi_session_lifecycle_test.dart) return 0 ;;
    *) return 1 ;;
  esac
}

# Emulator guard — the #589 contract: an absent emulator must be LOUD, never a
# silent pass.
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

PASS=()
FAIL=()

for abs in "${TESTS[@]}"; do
  rel="integration_test/$(basename "$abs")"
  log "=== running $rel ==="
  if needs_second_bridge "$abs"; then
    log "(enabling 2nd bridge port 2223 for multi-session)"
    if BRIDGE_PORT2="2223" "$CONNECT_TEST" "$rel"; then
      PASS+=("$rel")
    else
      FAIL+=("$rel")
    fi
  else
    if "$CONNECT_TEST" "$rel"; then
      PASS+=("$rel")
    else
      FAIL+=("$rel")
    fi
  fi
done

echo "> INTEGRATION SUITE RESULT: ${#PASS[@]} passed, ${#FAIL[@]} failed (of ${#TESTS[@]})"
for t in "${PASS[@]}"; do echo "  + $t"; done
for t in "${FAIL[@]}"; do echo "  ! $t"; done

if [[ "${#FAIL[@]}" -gt 0 ]]; then
  echo "! NATIVE INTEGRATION SUITE FAILED"
  exit 1
fi
echo "+ NATIVE INTEGRATION SUITE PASSED"
