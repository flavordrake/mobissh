#!/usr/bin/env bash
# scripts/lib/integration-manifest.sh — read, validate and ENFORCE the accepted
# #589 baseline recorded in native/integration_test/BASELINE.manifest (#1101).
#
# WHY THIS EXISTS. The suite's verdict used to be "any failure fails the run".
# Main has not been all-green for months (74 of 84 device tests pass; the other
# 10 have named causes and owning issues), so that verdict carried no information
# about the change under test and the pressure was to bypass the gate entirely.
# The verdict now compares the run against the accepted baseline:
#
#   expected-pass test fails   -> FAIL. The reason the gate exists.
#   known-red test fails       -> reported, not fatal.
#   known-red test PASSES      -> FAIL. Promote it and say which run proved it.
#                                 An excused test that silently recovered is how
#                                 the list rots back into "22 reds, nobody knows".
#   test on disk, unclassified -> FAIL. New tests are classified deliberately.
#
# The verdict is a PURE FUNCTION of (manifest, pass list, fail list), so all four
# conditions are provable with no emulator — scripts/test-integration-wiring.sh
# does exactly that in fast gate 0.
#
# Knobs (tests set these; runners leave them alone):
#   INTEGRATION_REPO_ROOT  repo root
#   INTEGRATION_MANIFEST   manifest path (default $root/native/integration_test/BASELINE.manifest)
#   INTEGRATION_TEST_DIR   corpus dir   (default $root/native/integration_test)

manifest_file() {
  if [[ -n "${INTEGRATION_MANIFEST:-}" ]]; then
    echo "$INTEGRATION_MANIFEST"
  else
    echo "${INTEGRATION_REPO_ROOT:-${REPO_ROOT:-}}/native/integration_test/BASELINE.manifest"
  fi
}

manifest_test_dir() {
  if [[ -n "${INTEGRATION_TEST_DIR:-}" ]]; then
    echo "$INTEGRATION_TEST_DIR"
  else
    echo "${INTEGRATION_REPO_ROOT:-${REPO_ROOT:-}}/native/integration_test"
  fi
}

_manifest_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Every record as `verb|field2|field3|field4`, trimmed, comments and blank lines
# dropped. Only WHOLE-LINE comments are supported — `#` is a legal character
# inside a field, because a known-red entry's issue reference starts with one.
manifest_records() {
  local f line verb a b c
  f="$(manifest_file)"
  [[ -f "$f" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(_manifest_trim "$line")"
    [[ -n "$line" ]] || continue
    [[ "${line:0:1}" == "#" ]] && continue
    IFS='|' read -r verb a b c <<< "$line"
    printf '%s|%s|%s|%s\n' \
      "$(_manifest_trim "${verb:-}")" "$(_manifest_trim "${a:-}")" \
      "$(_manifest_trim "${b:-}")" "$(_manifest_trim "${c:-}")"
  done < "$f"
}

# Normalise any way a runner names a test to its bare basename.
manifest_name() { basename "$1"; }

# `expect`, `known-red`, `elsewhere`, or empty when the test is in NEITHER list.
manifest_class() {
  local want rec a
  want="$(manifest_name "$1")"
  while IFS='|' read -r rec a _ _; do
    [[ "$rec" == "expect" || "$rec" == "known-red" || "$rec" == "elsewhere" ]] || continue
    [[ "$a" == "$want" ]] || continue
    echo "$rec"
    return 0
  done < <(manifest_records)
}

# Issue / reason of a known-red entry (empty for anything else).
manifest_known_red_issue()  { _manifest_field "$1" 3; }
manifest_known_red_reason() { _manifest_field "$1" 4; }
_manifest_field() {
  local want="$1" idx="$2" rec a b c
  want="$(manifest_name "$want")"
  while IFS='|' read -r rec a b c; do
    [[ "$rec" == "known-red" && "$a" == "$want" ]] || continue
    case "$idx" in 3) echo "$b" ;; 4) echo "$c" ;; esac
    return 0
  done < <(manifest_records)
}

manifest_list() {
  local want="$1" rec a
  while IFS='|' read -r rec a _ _; do
    [[ "$rec" == "$want" ]] && echo "$a"
  done < <(manifest_records)
  return 0
}

# --- validation ------------------------------------------------------------
# Prove the manifest is well-formed AGAINST THE CORPUS ON DISK: no entry naming
# a test that is not there, no duplicates, every test classified exactly once,
# every known-red carrying an issue AND a reason, `elsewhere` agreeing with the
# test's own `// Runner:` header, and the accepted tally matching the body.
# Prints one `!` line per problem; returns non-zero if there were any.
manifest_validate() {
  local f dir problems=0 rec a b c
  f="$(manifest_file)"
  dir="$(manifest_test_dir)"

  if [[ ! -f "$f" ]]; then
    echo "! manifest: ${f} does not exist" >&2
    return 1
  fi

  # `elsewhere` is cross-checked against the test's own `// Runner:` header, which
  # only integration-fixtures.sh knows how to read.
  if ! declare -F integration_declared_runner >/dev/null; then
    source "$(dirname "${BASH_SOURCE[0]}")/integration-fixtures.sh"
  fi

  local seen_accepted=0
  local -A class_of=() dup=()
  local n_expect=0 n_red=0 n_else=0

  while IFS='|' read -r rec a b c; do
    case "$rec" in
      # accepted | run-id | expect=N | known-red=N | elsewhere=N — the tally is
      # checked against the parsed body below, off the raw line (it has more
      # fields than the four a record is split into).
      accepted) seen_accepted=$((seen_accepted + 1)) ;;
      expect|known-red|elsewhere) : ;;
      *)
        echo "! manifest: unknown verb '${rec}' (line: ${rec}|${a}|${b}|${c})" >&2
        problems=$((problems + 1))
        continue
        ;;
    esac
    [[ "$rec" == "accepted" ]] && continue

    if [[ -z "$a" ]]; then
      echo "! manifest: a '${rec}' record names no test" >&2
      problems=$((problems + 1))
      continue
    fi
    if [[ ! -f "${dir}/${a}" ]]; then
      echo "! manifest: '${rec} | ${a}' names a test that is not on disk" >&2
      problems=$((problems + 1))
      continue
    fi
    if [[ -n "${dup[$a]:-}" ]]; then
      echo "! manifest: ${a} is classified more than once (${dup[$a]} and ${rec})" >&2
      problems=$((problems + 1))
      continue
    fi
    dup[$a]="$rec"
    class_of[$a]="$rec"

    case "$rec" in
      expect)
        n_expect=$((n_expect + 1))
        if [[ -n "$b" || -n "$c" ]]; then
          echo "! manifest: 'expect | ${a}' carries extra fields (${b}|${c})" >&2
          problems=$((problems + 1))
        fi
        ;;
      known-red)
        n_red=$((n_red + 1))
        if [[ ! "$b" =~ ^#[0-9]+$ ]]; then
          echo "! manifest: known-red ${a} has no issue reference (got '${b}') — a red nobody owns is not a baseline, it is a hole" >&2
          problems=$((problems + 1))
        fi
        if [[ -z "$c" ]]; then
          echo "! manifest: known-red ${a} (${b}) has no reason — say in one line why it is red" >&2
          problems=$((problems + 1))
        fi
        ;;
      elsewhere)
        n_else=$((n_else + 1))
        if [[ -z "$b" ]]; then
          echo "! manifest: elsewhere ${a} names no runner" >&2
          problems=$((problems + 1))
        fi
        ;;
    esac
  done < <(manifest_records)

  # Every test on disk classified exactly once, and `elsewhere` agreeing with the
  # test's own `// Runner:` declaration in BOTH directions.
  local path name declared
  for path in "${dir}"/*_test.dart; do
    [[ -e "$path" ]] || continue
    name="$(basename "$path")"
    if [[ -z "${class_of[$name]:-}" ]]; then
      echo "! manifest: ${name} is on disk but in NEITHER list — classify it (expect, or known-red with an issue)" >&2
      problems=$((problems + 1))
      continue
    fi
    declared="$(integration_declared_runner "$path" 2>/dev/null || true)"
    if [[ -n "$declared" && "${class_of[$name]}" != "elsewhere" ]]; then
      echo "! manifest: ${name} declares its own runner (${declared}) but is classified '${class_of[$name]}'" >&2
      problems=$((problems + 1))
    elif [[ -z "$declared" && "${class_of[$name]}" == "elsewhere" ]]; then
      echo "! manifest: ${name} is classified 'elsewhere' but declares no '// Runner:' header, so this suite WILL run it" >&2
      problems=$((problems + 1))
    fi
  done

  # The accepted tally. It is not bookkeeping for its own sake: moving a test
  # between sets is exactly the edit that must be noticed in review, and the
  # tally makes that edit impossible to make silently.
  if [[ "$seen_accepted" -ne 1 ]]; then
    echo "! manifest: expected exactly one 'accepted' record, found ${seen_accepted}" >&2
    problems=$((problems + 1))
  else
    local acc
    acc="$(grep -E '^[[:space:]]*accepted[[:space:]]*\|' "$f" | head -n 1)"
    local want
    for want in "expect=${n_expect}" "known-red=${n_red}" "elsewhere=${n_else}"; do
      if [[ "$acc" != *"$want"* ]]; then
        echo "! manifest: the accepted tally does not match the body — the body has ${want}" >&2
        echo "  accepted: ${acc}" >&2
        echo "  If you moved a test between sets, update the tally in the same edit and cite the run that justifies it." >&2
        problems=$((problems + 1))
      fi
    done
  fi

  [[ "$problems" -eq 0 ]]
}

# --- the verdict -----------------------------------------------------------
# manifest_verdict PASS_FILE FAIL_FILE — each file one test per line (any naming;
# basenames are taken). Prints the operator summary, names any drift condition it
# finds, and returns 0 only when the run matches the accepted baseline.
manifest_verdict() {
  local pass_file="$1" fail_file="$2"
  local -A passed=() failed=()
  local t n

  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    passed["$(manifest_name "$t")"]=1
  done < "$pass_file"
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    failed["$(manifest_name "$t")"]=1
  done < "$fail_file"

  local -a unexpected_fail=() expected_fail=() recovered=() unclassified=()
  local cls
  for n in "${!failed[@]}"; do
    cls="$(manifest_class "$n")"
    case "$cls" in
      expect)    unexpected_fail+=("$n") ;;
      known-red) expected_fail+=("$n") ;;
      *)         unclassified+=("$n") ;;
    esac
  done
  for n in "${!passed[@]}"; do
    cls="$(manifest_class "$n")"
    case "$cls" in
      known-red) recovered+=("$n") ;;
      expect)    : ;;
      *)         unclassified+=("$n") ;;
    esac
  done

  local n_expected_total n_pass_expected=0
  n_expected_total="$(manifest_list expect | grep -c . || true)"
  for n in "${!passed[@]}"; do
    [[ "$(manifest_class "$n")" == "expect" ]] && n_pass_expected=$((n_pass_expected + 1))
  done

  echo "> BASELINE: ${n_pass_expected}/${n_expected_total} expected-pass tests passed; ${#expected_fail[@]} known-red failed as expected"

  local rc=0
  if [[ "${#expected_fail[@]}" -gt 0 ]]; then
    echo "  known-red (reported, not fatal — each owned by an issue):"
    while IFS= read -r n; do
      [[ -n "$n" ]] || continue
      echo "    ~ ${n}  $(manifest_known_red_issue "$n")  $(manifest_known_red_reason "$n")"
    done < <(printf '%s\n' "${expected_fail[@]}" | sort)
  fi

  if [[ "${#unexpected_fail[@]}" -gt 0 ]]; then
    rc=1
    echo "! DRIFT — EXPECTED-PASS TEST FAILED (${#unexpected_fail[@]}). This is the gate doing its job:"
    while IFS= read -r n; do [[ -n "$n" ]] && echo "    ! ${n}"; done \
      < <(printf '%s\n' "${unexpected_fail[@]}" | sort)
    echo "  These passed on clean main in the accepted baseline. Fix the change, or"
    echo "  re-baseline with evidence — do not move them to known-red to go green."
  fi

  if [[ "${#recovered[@]}" -gt 0 ]]; then
    rc=1
    echo "! DRIFT — KNOWN-RED TEST PASSED (${#recovered[@]}). Promote it:"
    while IFS= read -r n; do
      [[ -n "$n" ]] || continue
      echo "    + ${n}  (was excused by $(manifest_known_red_issue "$n"))"
    done < <(printf '%s\n' "${recovered[@]}" | sort)
    echo "  Move each to 'expect' in native/integration_test/BASELINE.manifest and"
    echo "  bump the accepted tally, citing this run. A recovered test that stays"
    echo "  excused is how the baseline rots."
  fi

  if [[ "${#unclassified[@]}" -gt 0 ]]; then
    rc=1
    echo "! DRIFT — TEST IN NEITHER LIST (${#unclassified[@]}):"
    while IFS= read -r n; do [[ -n "$n" ]] && echo "    ? ${n}"; done \
      < <(printf '%s\n' "${unclassified[@]}" | sort -u)
    echo "  Add each to native/integration_test/BASELINE.manifest. A new test must be"
    echo "  classified deliberately; defaulting to excused is not classification."
  fi

  return "$rc"
}
