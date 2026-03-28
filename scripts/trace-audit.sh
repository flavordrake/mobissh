#!/usr/bin/env bash
# scripts/trace-audit.sh — Audit all TRACE directories for completeness
#
# Checks each trace for:
#   - TRACE.md exists and is populated (not boilerplate)
#   - Status field is set (not empty or default)
#   - Strategy/initial_plan.md exists and has content
#   - Knowledge seeds present (not just comments)
#   - Outcome classification present
#   - Decisions captured
#
# Output: table of all traces with pass/fail per check

set -euo pipefail
cd "$(dirname "$0")/.."

TRACES_DIR=".traces"
if [[ ! -d "$TRACES_DIR" ]]; then
  echo "No .traces/ directory found"
  exit 0
fi

TOTAL=0
COMPLETE=0
INCOMPLETE=0
EMPTY=0

printf "%-55s %-10s %-8s %-8s %-8s %-8s %-8s\n" "TRACE" "STATUS" "PLAN" "SEEDS" "OUTCOME" "DECIDE" "GRADE"
printf "%-55s %-10s %-8s %-8s %-8s %-8s %-8s\n" "-----" "------" "----" "-----" "-------" "------" "-----"

for trace_dir in "$TRACES_DIR"/trace-*/; do
  [[ ! -d "$trace_dir" ]] && continue
  TOTAL=$((TOTAL + 1))
  name=$(basename "$trace_dir")
  trace_md="$trace_dir/TRACE.md"
  plan_md="$trace_dir/strategy/initial_plan.md"

  # Check TRACE.md exists
  if [[ ! -f "$trace_md" ]]; then
    printf "%-55s %-10s %-8s %-8s %-8s %-8s %-8s\n" "$name" "MISSING" "-" "-" "-" "-" "F"
    EMPTY=$((EMPTY + 1))
    continue
  fi

  # Check status field
  status=$(grep -oP '^status:\s*\K\S+' "$trace_md" 2>/dev/null || echo "none")
  if [[ "$status" == "in-progress" || "$status" == "none" ]]; then
    status_ok="INPROG"
  elif [[ "$status" == "success" || "$status" == "success-with-caveats" || "$status" == "partial" || "$status" == "failure-informative" || "$status" == "failure" ]]; then
    status_ok="$status"
  else
    status_ok="?"
  fi

  # Check boilerplate (unpopulated)
  if grep -q "<!-- Post-mortem" "$trace_md" 2>/dev/null; then
    printf "%-55s %-10s %-8s %-8s %-8s %-8s %-8s\n" "$name" "BOILER" "-" "-" "-" "-" "F"
    EMPTY=$((EMPTY + 1))
    continue
  fi

  # Check initial plan
  plan="MISS"
  if [[ -f "$plan_md" ]]; then
    plan_lines=$(grep -cv "^#\|^$\|^<!--" "$plan_md" 2>/dev/null || echo 0)
    if [[ "$plan_lines" -gt 2 ]]; then
      plan="OK"
    else
      plan="THIN"
    fi
  fi

  # Check knowledge seeds
  seeds="MISS"
  if grep -qiP "knowledge seed|knowledge seeds" "$trace_md" 2>/dev/null; then
    seed_content=$(sed -n '/[Kk]nowledge [Ss]eed/,/^##/p' "$trace_md" | grep -cv "^#\|^$\|^<!--\|pending" 2>/dev/null || echo 0)
    if [[ "$seed_content" -gt 0 ]]; then
      seeds="OK"
    else
      seeds="EMPTY"
    fi
  fi

  # Check outcome classification
  outcome="MISS"
  if grep -qiP "outcome|classification" "$trace_md" 2>/dev/null; then
    outcome_content=$(sed -n '/[Oo]utcome/,/^##/p' "$trace_md" | grep -cv "^#\|^$\|^<!--" 2>/dev/null || echo 0)
    if [[ "$outcome_content" -gt 0 ]]; then
      outcome="OK"
    else
      outcome="EMPTY"
    fi
  fi

  # Check for decisions
  decisions="MISS"
  if grep -qiP "decision|decisions" "$trace_md" 2>/dev/null; then
    decision_count=$(grep -ciP "^\d+\.|^- " "$trace_md" 2>/dev/null || echo 0)
    if [[ "$decision_count" -gt 0 ]]; then
      decisions="$decision_count"
    else
      decisions="EMPTY"
    fi
  fi

  # Grade
  grade="F"
  ok_count=0
  [[ "$plan" == "OK" ]] && ok_count=$((ok_count + 1))
  [[ "$seeds" == "OK" ]] && ok_count=$((ok_count + 1))
  [[ "$outcome" == "OK" ]] && ok_count=$((ok_count + 1))
  [[ "$decisions" != "MISS" && "$decisions" != "EMPTY" ]] && ok_count=$((ok_count + 1))

  if [[ "$ok_count" -ge 4 ]]; then
    grade="A"
    COMPLETE=$((COMPLETE + 1))
  elif [[ "$ok_count" -ge 3 ]]; then
    grade="B"
    COMPLETE=$((COMPLETE + 1))
  elif [[ "$ok_count" -ge 2 ]]; then
    grade="C"
    INCOMPLETE=$((INCOMPLETE + 1))
  elif [[ "$ok_count" -ge 1 ]]; then
    grade="D"
    INCOMPLETE=$((INCOMPLETE + 1))
  else
    grade="F"
    EMPTY=$((EMPTY + 1))
  fi

  printf "%-55s %-10s %-8s %-8s %-8s %-8s %-8s\n" "$name" "$status_ok" "$plan" "$seeds" "$outcome" "$decisions" "$grade"
done

echo ""
echo "Total: $TOTAL traces | Complete (A/B): $COMPLETE | Incomplete (C/D): $INCOMPLETE | Empty/Boiler (F): $EMPTY"
