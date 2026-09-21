#!/usr/bin/env bash
# scripts/test-integration-wiring.sh — pin scripts/lib/integration-fixtures.sh
# against the REAL integration-test corpus (#1101 G0-G3). Runs in fast gate 0
# (pure bash, sub-second, no emulator).
#
# WHAT THIS GUARDS. The runner used to keep its own hand-written copy of what
# each test needs — twice, in two scripts. Both copies drifted from the tests
# that declare the requirement in their own headers, and the #1101 baseline
# burned two tests on it: `reconnect_mouse_mode_1014` and
# `reconnect_da_writeback_leak_1072` both say "Bridge: BRIDGE_PORT2=2223" at the
# top of the file and were in NEITHER list, so both failed "session B never
# reached the terminal" — a harness gap that reads exactly like a product bug.
#
# So this test asserts the two things that let that happen cannot recur:
#   1. the runners hold NO predicate of their own (one shared definition), and
#   2. the shared definition agrees with what the test files declare — checked
#      against every test on disk, not a fixture list that can go stale.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INTEGRATION_REPO_ROOT="$REPO_ROOT"
ITEST_DIR="${REPO_ROOT}/native/integration_test"
source "${REPO_ROOT}/scripts/lib/integration-fixtures.sh"

PASS=0
FAIL=0
ok()  { echo "+ $1"; PASS=$((PASS + 1)); }
bad() { echo "! $1"; FAIL=$((FAIL + 1)); }

# 1. NO runner keeps a predicate of its own. This is the drift root: two copies
#    of the same rule, maintained by hand, in two files.
for runner in native-integration-suite.sh integration-subset.sh; do
  if grep -qE '^[a-z_]*needs_(second_bridge|jump_target)\(\)' "${REPO_ROOT}/scripts/${runner}"; then
    bad "${runner} defines its own needs_* predicate — that is the drift (#1101 G3)"
  else
    ok "${runner} keeps no predicate of its own"
  fi
  if grep -q 'scripts/lib/integration-fixtures.sh' "${REPO_ROOT}/scripts/${runner}"; then
    ok "${runner} sources the shared wiring library"
  else
    bad "${runner} does not source scripts/lib/integration-fixtures.sh"
  fi
done

# 2. The bridge predicate agrees with EVERY test's own declaration. A test that
#    names 127.0.0.1:2223 opens a second session there; without the bridge it
#    has nowhere to connect.
for f in "$ITEST_DIR"/*_test.dart; do
  name="$(basename "$f")"
  if grep -q '2223' "$f"; then
    if integration_needs_second_bridge "$f"; then
      ok "second bridge armed for ${name} (it declares 2223)"
    else
      bad "${name} declares 2223 but the runner would NOT arm the 2nd bridge"
    fi
  elif integration_needs_second_bridge "$f"; then
    bad "${name} does not declare 2223 but the runner would arm the 2nd bridge"
  fi
done

# 3. Regression anchors: the two tests the baseline proved red->green must be in.
for anchor in reconnect_mouse_mode_1014_test.dart reconnect_da_writeback_leak_1072_test.dart; do
  if integration_needs_second_bridge "${ITEST_DIR}/${anchor}"; then
    ok "#1101 G3 anchor: ${anchor} gets its second bridge"
  else
    bad "#1101 G3 anchor MISSING: ${anchor} would run without BRIDGE_PORT2"
  fi
done

# 4. Every declared setup/teardown script must EXIST and be executable —
#    otherwise the runner brackets a test with a prerequisite that cannot run.
declares_nested=0
for f in "$ITEST_DIR"/*_test.dart; do
  name="$(basename "$f")"
  while read -r s; do
    [[ -n "$s" ]] || continue
    if [[ -x "${REPO_ROOT}/${s}" ]]; then
      ok "${name} prerequisite ${s} exists and is executable"
    else
      bad "${name} declares ${s}, which is missing or not executable"
    fi
  done < <(integration_setup_scripts "$f"; integration_teardown_scripts "$f")

  # 5. THE POISON RULE. cc-nested-setup.sh installs a ~/.bash_profile that
  #    `exec tmux attach` on every interactive login. A test that asks for it
  #    and does NOT declare the matching teardown would break every later test
  #    on the same fixture, and the breakage would look like a product bug.
  if integration_setup_scripts "$f" | grep -q 'cc-nested-setup.sh'; then
    declares_nested=$((declares_nested + 1))
    if integration_teardown_scripts "$f" | grep -q 'cc-nested-teardown.sh'; then
      ok "${name} declares the nested-tmux teardown with its setup"
    else
      bad "${name} installs the nested-login guard with NO teardown — it would poison every later test"
    fi
  fi
done
if [[ "$declares_nested" -ge 1 ]]; then
  ok "the nested-tmux fixture is still exercised (${declares_nested} tests)"
else
  bad "expected >=1 test to use cc-nested-setup.sh, found ${declares_nested}"
fi

# 6. Platform: exactly the desktop smoke declares its own runner, and it is the
#    desktop one. The Android suite ran it against the guest, where `test-sshd`
#    is unresolvable, so it was a permanent fake red (#1101 G2).
declared=()
for f in "$ITEST_DIR"/*_test.dart; do
  r="$(integration_declared_runner "$f")"
  [[ -n "$r" ]] && declared+=("$(basename "$f") → $r")
done
if [[ "${#declared[@]}" -eq 1 && "${declared[0]}" == desktop_smoke_test.dart* ]]; then
  ok "only desktop_smoke_test.dart opts out of the Android suite (${declared[0]})"
else
  bad "unexpected set of tests declaring their own runner: ${declared[*]:-none}"
fi
if integration_declared_runner "${ITEST_DIR}/desktop_smoke_test.dart" | grep -q 'desktop-smoke.sh'; then
  ok "desktop_smoke names scripts/desktop-smoke.sh as its runner"
else
  bad "desktop_smoke does not name its real runner"
fi

# 7. The parser itself, against synthetic declarations — so the rules above are
#    testing a parser that works, not one that happens to match today's corpus.
SANDBOX="$(mktemp -d "${MOBISSH_TMPDIR:-/tmp/mobissh}/integration-wiring-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "${SANDBOX}/native/integration_test"
SYN="${SANDBOX}/native/integration_test/synthetic_test.dart"
{
  echo "// Runner: scripts/somewhere-else.sh (not this suite)"
  echo "// Setup (run FIRST): scripts/one-setup.sh"
  echo "// Setup (run FIRST): scripts/two-setup.sh"
  echo "// Teardown (restore the world): scripts/one-teardown.sh"
  echo "// connects a second session on 127.0.0.1:2223"
  echo "// reaches jump-target through the bastion"
} > "$SYN"
: > "${SANDBOX}/native/integration_test/plain_test.dart"
INTEGRATION_REPO_ROOT="$SANDBOX"

got="$(integration_setup_scripts integration_test/synthetic_test.dart | tr '\n' ',')"
if [[ "$got" == "scripts/one-setup.sh,scripts/two-setup.sh," ]]; then
  ok "parser: both declared setup scripts, in order"
else
  bad "parser: setup scripts wrong (${got})"
fi
got="$(integration_teardown_scripts integration_test/synthetic_test.dart)"
if [[ "$got" == "scripts/one-teardown.sh" ]]; then
  ok "parser: teardown parsed regardless of its parenthetical"
else
  bad "parser: teardown wrong (${got})"
fi
got="$(integration_declared_runner integration_test/synthetic_test.dart)"
if [[ "$got" == "scripts/somewhere-else.sh (not this suite)" ]]; then
  ok "parser: declared runner parsed"
else
  bad "parser: runner wrong (${got})"
fi
if integration_needs_second_bridge integration_test/synthetic_test.dart; then
  ok "parser: 2223 anywhere in the source arms the bridge"
else
  bad "parser: missed a declared 2223"
fi
if integration_needs_jump_target integration_test/synthetic_test.dart; then
  ok "parser: jump-target anywhere in the source brings up the target"
else
  bad "parser: missed a declared jump-target"
fi
if integration_needs_second_bridge integration_test/plain_test.dart \
   || integration_needs_jump_target integration_test/plain_test.dart \
   || [[ -n "$(integration_declared_runner integration_test/plain_test.dart)" ]] \
   || [[ -n "$(integration_setup_scripts integration_test/plain_test.dart)" ]]; then
  bad "parser: a test declaring nothing got wiring anyway"
else
  ok "parser: a test declaring nothing gets no extra wiring"
fi

INTEGRATION_REPO_ROOT="$REPO_ROOT"
echo "integration-wiring: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
