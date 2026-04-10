#!/usr/bin/env bash
# scripts/crystallize-test.sh — Integration tests for the crystallize skill.
#
# Runs crystallize-audit.sh against three historical fixture sets and
# compares the output to known human decisions. Each candidate has a
# MANIFEST.md with the ground truth (what the human extracted).
#
# Exit code:
#   0 — all checks passed
#   1 — at least one check failed
#
# Usage: scripts/crystallize-test.sh

set -euo pipefail
cd "$(dirname "$0")/.."

TESTS_DIR=".claude/skills/crystallize/tests"
AUDIT="scripts/crystallize-audit.sh"
PASS=0
FAIL=0
TOTAL=0

check() {
  local desc="$1"
  local result="$2"  # "pass" or "fail"
  TOTAL=$((TOTAL + 1))
  if [[ "$result" == "pass" ]]; then
    PASS=$((PASS + 1))
    echo "  [PASS] $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  [FAIL] $desc"
  fi
}

echo "=== Candidate 1: delegate ==="
echo ""

DELEGATE_OUT=$($AUDIT --skill "$TESTS_DIR/delegate/SKILL-before.md")

# Check: audit finds signal matches (at least 1)
DELEGATE_SIGNALS=$(echo "$DELEGATE_OUT" | jq '.signal_matches | length')
if [[ "$DELEGATE_SIGNALS" -gt 0 ]]; then
  check "Phase 1: found $DELEGATE_SIGNALS signal match(es)" "pass"
else
  check "Phase 1: found signal matches" "fail"
fi

# Check: audit finds scripts already invoked (ground truth: >= 5)
DELEGATE_INVOKED=$(echo "$DELEGATE_OUT" | jq '.scripts_invoked | length')
if [[ "$DELEGATE_INVOKED" -ge 5 ]]; then
  check "Phase 1: found $DELEGATE_INVOKED scripts already invoked (A-bucket)" "pass"
else
  check "Phase 1: found >= 5 scripts invoked" "fail"
fi

# Check: gh-ops.sh IS in the invoked list (ground truth: the wrapper exists)
if echo "$DELEGATE_OUT" | jq -e '.scripts_invoked[] | select(. == "scripts/gh-ops.sh")' > /dev/null 2>&1; then
  check "Phase 2: gh-ops.sh wrapper is in invoked list" "pass"
else
  check "Phase 2: gh-ops.sh wrapper found" "fail"
fi

# Check: raw gh CLI call detected (ground truth: should use gh-ops.sh/gh-file-issue.sh)
if echo "$DELEGATE_OUT" | jq -e '.signal_matches[] | select(.phrase | test("gh "))' > /dev/null 2>&1; then
  check "Phase 1: detected raw gh CLI invocation (B-bucket candidate)" "pass"
else
  check "Phase 1: detected raw gh CLI call" "fail"
fi

echo ""
echo "=== Candidate 2: agent-trace ==="
echo ""

TRACE_OUT=$($AUDIT --skill "$TESTS_DIR/agent-trace/SKILL-before.md")

# Check: trace-file-history.sh is in orphaned list (ground truth)
if echo "$TRACE_OUT" | jq -e '.scripts_orphaned[] | select(. == "scripts/trace-file-history.sh")' > /dev/null 2>&1; then
  check "Phase 2: trace-file-history.sh found as orphaned" "pass"
else
  check "Phase 2: trace-file-history.sh in orphaned list" "fail"
fi

# Check: trace-symbol-history.sh is in orphaned list (ground truth)
if echo "$TRACE_OUT" | jq -e '.scripts_orphaned[] | select(. == "scripts/trace-symbol-history.sh")' > /dev/null 2>&1; then
  check "Phase 2: trace-symbol-history.sh found as orphaned" "pass"
else
  check "Phase 2: trace-symbol-history.sh in orphaned list" "fail"
fi

# Check: trace-init.sh IS in invoked list (it's already used by the skill)
if echo "$TRACE_OUT" | jq -e '.scripts_invoked[] | select(. == "scripts/trace-init.sh")' > /dev/null 2>&1; then
  check "Phase 1: trace-init.sh correctly identified as already invoked (A-bucket)" "pass"
else
  check "Phase 1: trace-init.sh in invoked list" "fail"
fi

# Check: TRACE snapshot exists for phase 5 comparison
if [[ -f "$TESTS_DIR/agent-trace/trace-snapshot/TRACE.md" ]]; then
  check "Fixture: TRACE snapshot exists for phase 5 LLM-vs-script comparison" "pass"
else
  check "Fixture: TRACE snapshot exists" "fail"
fi

echo ""
echo "=== Candidate 3: boot-splash ==="
echo ""

# Boot-splash is a code-module extraction, not a SKILL.md compaction.
# The test verifies the fixture integrity and the probe module structure.

if [[ -f "$TESTS_DIR/boot-splash/connection-before.ts" ]]; then
  check "Fixture: connection-before.ts exists" "pass"
else
  check "Fixture: connection-before.ts exists" "fail"
fi

if [[ -f "$TESTS_DIR/boot-splash/connect-probe.ts" ]]; then
  check "Fixture: extracted probe module exists" "pass"
else
  check "Fixture: connect-probe.ts exists" "fail"
fi

if [[ -f "$TESTS_DIR/boot-splash/connect-probe.test.ts" ]]; then
  check "Fixture: 16-test suite exists" "pass"
else
  check "Fixture: connect-probe.test.ts exists" "fail"
fi

# Check: the before-version has the inline 5s timeout but NO probe import
if grep -q '_showConnectionStatus' "$TESTS_DIR/boot-splash/connection-before.ts" && \
   ! grep -q 'probeConnectLayers' "$TESTS_DIR/boot-splash/connection-before.ts"; then
  check "Before-state: has 5s timeout, no probe import (confirms extraction happened)" "pass"
else
  check "Before-state: has 5s timeout without probe" "fail"
fi

# Check: the after-version imports and calls the probe
if grep -q 'probeConnectLayers' "$TESTS_DIR/boot-splash/connection-after.ts"; then
  check "After-state: imports and calls probeConnectLayers (confirms wiring)" "pass"
else
  check "After-state: probeConnectLayers wired in" "fail"
fi

# Check: the probe module is a pure function (no DOM, no global state)
if ! grep -q 'document\.\|window\.\|localStorage' "$TESTS_DIR/boot-splash/connect-probe.ts"; then
  check "Probe module: pure function (no DOM, no globals)" "pass"
else
  check "Probe module: no DOM/global access" "fail"
fi

echo ""
echo "=== Summary ==="
echo ""
echo "  $PASS/$TOTAL passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
