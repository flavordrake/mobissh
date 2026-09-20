#!/usr/bin/env bash
# scripts/lib/integration-fixtures.sh — the ONE definition of what each
# integration test needs from the runner (#1101, groups G0-G3).
#
# WHY THIS EXISTS. `native-integration-suite.sh` and `integration-subset.sh` each
# carried their own hand-written copy of `needs_second_bridge()` /
# `needs_jump_target()`. Both copies drifted from the tests that DECLARE the
# requirement in their own headers, and the #1101 baseline caught it twice in one
# day: `reconnect_mouse_mode_1014` and `reconnect_da_writeback_leak_1072` both say
# "Bridge: BRIDGE_PORT2=2223" at the top of the file and were in NEITHER list, so
# both failed with "session B never reached the terminal" — a HARNESS gap that
# reads exactly like a product regression.
#
# THE RULE: DERIVE, DON'T DUPLICATE. Every fact the runner needs is already
# stated in the test source, in a greppable form. This library reads it from
# there; the runners source this library and keep no list of their own.
# `scripts/test-integration-wiring.sh` (fast gate 0) pins the derivation against
# the real test corpus, so a new test's declaration cannot be silently ignored.
#
# Declarations a test can make, all in its header comment:
#   `2223` anywhere in the source        → needs the SECOND socat+adb-reverse
#                                          bridge (BRIDGE_PORT2=2223)
#   `jump-target` anywhere in the source → needs the 2nd sshd container up
#   // Setup (run FIRST): scripts/x.sh   → runner runs x.sh BEFORE the test
#   // Teardown …: scripts/y.sh          → runner runs y.sh AFTER it, always
#   // Runner: scripts/z.sh …            → this test does NOT belong to the
#                                          Android device suite; z.sh owns it
#
# Source it from a runner:
#   source "$(dirname "$0")/lib/integration-fixtures.sh"

# Absolute path of an integration test named either way the runners name them:
# `integration_test/foo_test.dart` (relative to native/) or an absolute path.
integration_test_path() {
  local t="$1" root="${INTEGRATION_REPO_ROOT:-${REPO_ROOT:-}}"
  case "$t" in
    /*) echo "$t" ;;
    native/*) echo "${root}/${t}" ;;
    *) echo "${root}/native/${t}" ;;
  esac
}

# --- G3: the SECOND bridge -------------------------------------------------
# Six tests open a second session on 127.0.0.1:2223 and every one of them names
# that port in its own source. Grepping for it yields exactly the right set —
# including `service_outlives_ui_reconnect`, which never asserted B reached a
# terminal and so passed without the bridge by luck. Arming a bridge a test does
# not use costs one socat and one `adb reverse`; NOT arming one it does need
# costs an hour of chasing a phantom product bug.
integration_needs_second_bridge() {
  local f
  f="$(integration_test_path "$1")"
  [[ -f "$f" ]] || return 1
  grep -q '2223' "$f"
}

# --- #1183: the jump-host target container ---------------------------------
# The acceptance test reaches `jump-target` THROUGH test-sshd. No extra bridge —
# the device never dials the target — but the second container has to be up.
integration_needs_jump_target() {
  local f
  f="$(integration_test_path "$1")"
  [[ -f "$f" ]] || return 1
  grep -q 'jump-target' "$f"
}

# --- G2: tests that are NOT the Android device suite's ---------------------
# Echoes the runner a test declares for itself, empty if it is a plain device
# test. `desktop_smoke_test.dart` runs `-d linux` on the HOST under Xvfb and
# reaches test-sshd over the docker network directly; run against the Android
# guest it can never resolve `test-sshd` and fails "never reached the terminal".
integration_declared_runner() {
  local f
  f="$(integration_test_path "$1")"
  [[ -f "$f" ]] || return 0
  sed -n 's|^// Runner: *||p' "$f" | head -n 1
}

# --- G1: per-test setup / teardown scripts ---------------------------------
# Six control-mode tests need a tmux fixture built on the sshd BEFORE the app
# connects; each names its script in its header. TEARDOWN IS NOT OPTIONAL:
# cc-nested-setup.sh installs a ~/.bash_profile that `exec tmux attach` on every
# interactive login, so skipping the teardown poisons every later test on that
# fixture. Echo one script path per line ("" when none).
integration_setup_scripts() {
  local f
  f="$(integration_test_path "$1")"
  [[ -f "$f" ]] || return 0
  sed -n 's|^// Setup (run FIRST): *||p' "$f"
}

integration_teardown_scripts() {
  local f
  f="$(integration_test_path "$1")"
  [[ -f "$f" ]] || return 0
  sed -n 's|^// Teardown[^:]*: *||p' "$f"
}

# --- Run ONE test with everything it declared ------------------------------
# The whole per-test bracket, in one place, so the suite and the subset runner
# cannot wire a test up differently (the phase-2 subset run in the #1101 baseline
# is only comparable to the suite because the two wirings matched — by luck).
# Returns 0 on pass, 1 on fail. Never skips: the caller decides that.
integration_run_one() {
  local t="$1" abs root rc=0 s
  local -a setups=() teardowns=()
  root="${INTEGRATION_REPO_ROOT:-${REPO_ROOT:-}}"
  abs="$(integration_test_path "$t")"

  # Read BOTH lists before running anything. The setup scripts ssh into the
  # fixture, and ssh reads stdin — iterating straight off a process substitution
  # would let it swallow the rest of the list.
  mapfile -t setups < <(integration_setup_scripts "$abs")
  mapfile -t teardowns < <(integration_teardown_scripts "$abs")

  if integration_needs_jump_target "$abs"; then
    echo "> (bringing up the jump-target sshd for the jump-host acceptance)"
    "${root}/scripts/test-sshd-up.sh"
  fi

  # Prerequisites the test declares in its own header. A setup that fails is a
  # FAILED test, not a skipped one — the test cannot pass without it, and
  # running it anyway produces a misleading product-shaped error.
  for s in "${setups[@]}"; do
    [[ -n "$s" ]] || continue
    echo "> (setup for ${t}: ${s})"
    if ! "${root}/${s}" < /dev/null; then
      echo "! setup ${s} FAILED — not running ${t}" >&2
      rc=1
    fi
  done

  if [[ "$rc" -eq 0 ]]; then
    if integration_needs_second_bridge "$abs"; then
      echo "> (enabling 2nd bridge port 2223 — the test declares 127.0.0.1:2223)"
      BRIDGE_PORT2="2223" "${root}/scripts/native-connect-test.sh" "$t" || rc=1
    else
      "${root}/scripts/native-connect-test.sh" "$t" || rc=1
    fi
  fi

  # TEARDOWN ALWAYS, including after a failure. cc-nested-setup.sh installs a
  # ~/.bash_profile that `exec tmux attach` on every interactive login; leaving
  # it in place breaks every later test that connects to this fixture.
  for s in "${teardowns[@]}"; do
    [[ -n "$s" ]] || continue
    echo "> (teardown for ${t}: ${s})"
    "${root}/${s}" < /dev/null \
      || echo "! teardown ${s} FAILED — later tests may be poisoned" >&2
  done

  return "$rc"
}

# --- G0: a CURRENT, UNAMBIGUOUS sshd fixture -------------------------------
# Two independent hazards (#1187) silently change WHICH sshd a run talks to, and
# the #1101 baseline proved both are load-bearing: pinning the fixture moved
# `port_forward_1047` and `sftp_browse_smoke` from FAIL to PASS with no code
# change, and the baseline before it was not reproducible at all.
#
#   1. A cached image can predate the feature it serves (the canonical fixture
#      ran `AllowTcpForwarding no` — pre-#1047 — for six weeks). test-sshd-up.sh
#      now BUILDS, so the fixture is derived from the current Dockerfile.
#   2. Several containers answer to the `test-sshd` network ALIAS, and Docker DNS
#      round-robins among them. Pin the per-project CONTAINER name instead.
#
# Exports SSHD_HOST for the whole run. A caller-set SSHD_HOST always wins (the
# operator pinning a specific fixture by hand is the whole point of the knob).
integration_pin_fixture() {
  local root="${INTEGRATION_REPO_ROOT:-${REPO_ROOT:-}}"
  source "${root}/scripts/lib/testsshd-fixture.sh"

  if [[ -n "${SSHD_HOST:-}" ]]; then
    echo "> fixture: SSHD_HOST=${SSHD_HOST} (caller-pinned, honoured as-is)"
    export SSHD_HOST
    return 0
  fi

  echo "> fixture: bringing up a CURRENT test-sshd and pinning it (#1187)"
  if ! "${root}/scripts/test-sshd-up.sh"; then
    echo "! fixture: test-sshd-up.sh failed — cannot pin a fixture" >&2
    return 1
  fi

  local project container
  project="$(cd "$root" && testsshd_compose_project)"
  container="${project}-test-sshd-1"
  if ! getent hosts "$container" >/dev/null 2>&1; then
    # Not resolvable by container name (e.g. an environment where compose names
    # differently). Fall back to the alias rather than failing the whole run,
    # but say so — this is the ambiguous path.
    echo "! fixture: ${container} not resolvable; falling back to the AMBIGUOUS" >&2
    echo "  'test-sshd' alias — runs may not be reproducible (#1187)" >&2
    export SSHD_HOST="test-sshd"
    return 0
  fi
  export SSHD_HOST="$container"
  echo "> fixture: SSHD_HOST=${SSHD_HOST} (unambiguous container, pinned for the run)"
}
