#!/usr/bin/env bash
# scripts/test-lcov-summary.sh — pin scripts/lcov-summary.sh against a tiny
# fixture lcov (#1152): percent math, ascending sort, per-directory rollup,
# the NEVER-LOADED list (source files with no SF: record, minus test and
# generated files), and the --markdown form. Gate-0 style, pure bash, no
# Flutter or node involved.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUMMARY="${REPO_ROOT}/scripts/lcov-summary.sh"
SANDBOX="$(mktemp -d "${MOBISSH_TMPDIR:-/tmp/mobissh}/lcov-summary-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0
FAIL=0
ok()  { echo "+ $1"; PASS=$((PASS + 1)); }
bad() { echo "! $1"; FAIL=$((FAIL + 1)); }
# check_line LABEL EXPECTED_LINE OUTPUT — exact-line match (tabs preserved).
check_line() {
  if grep -qxF -- "$2" <<<"$3"; then ok "$1"; else bad "$1 (missing: $2)"; fi
}
check_absent() {
  if grep -qF -- "$2" <<<"$3"; then bad "$1 (unexpected: $2)"; else ok "$1"; fi
}
T=$'\t'

# Fixture: a dart tree with 2 fully covered files, 1 partially covered, 1
# never loaded, plus a test file and a generated file that must NOT be
# reported as never loaded. One SF record is absolute (vitest style), the
# rest relative (flutter style), and one file is recorded twice (per-test
# records must union, not double count).
SRC="$SANDBOX/native/lib"
mkdir -p "$SRC/ui" "$SRC/util"
touch "$SRC/a.dart" "$SRC/ui/b.dart" "$SRC/ui/c.dart" "$SRC/util/d.dart" \
      "$SRC/util/d_test.dart" "$SRC/util/e.g.dart"
LCOV="$SANDBOX/lcov.info"
cat >"$LCOV" <<EOF
SF:lib/a.dart
DA:1,1
DA:2,3
DA:3,0
LF:3
LH:2
end_of_record
SF:lib/a.dart
DA:3,1
DA:4,1
LF:2
LH:2
end_of_record
SF:$SRC/ui/b.dart
DA:1,1
DA:2,1
LF:2
LH:2
end_of_record
SF:lib/ui/c.dart
DA:1,1
DA:2,0
DA:3,0
DA:4,0
LF:4
LH:1
end_of_record
EOF

# 1. TSV form.
out="$("$SUMMARY" "$LCOV" "$SRC")"
check_line "partial file percent"        "file${T}lib/ui/c.dart${T}1${T}4${T}25.0" "$out"
check_line "duplicate records union"     "file${T}lib/a.dart${T}4${T}4${T}100.0" "$out"
check_line "absolute SF path normalised" "file${T}lib/ui/b.dart${T}2${T}2${T}100.0" "$out"
check_line "dir rollup lib/ui"           "dir${T}lib/ui${T}3${T}6${T}50.0" "$out"
check_line "dir rollup lib"              "dir${T}lib${T}4${T}4${T}100.0" "$out"
check_line "total"                       "total${T}lib${T}7${T}10${T}70.0" "$out"
check_line "never-loaded file listed"    "never-loaded${T}lib/util/d.dart" "$out"
check_line "never-loaded count"          "never-loaded-count${T}1" "$out"
check_absent "test file not never-loaded"      "d_test.dart" "$out"
check_absent "generated file not never-loaded" "e.g.dart" "$out"
files="$(grep '^file' <<<"$out" | cut -f2 | tr '\n' ' ')"
if [[ "$files" == "lib/ui/c.dart lib/a.dart lib/ui/b.dart " ]]; then
  ok "files sorted percent ascending, then path"
else
  bad "file sort order ($files)"
fi
dirs="$(grep '^dir' <<<"$out" | cut -f2 | tr '\n' ' ')"
if [[ "$dirs" == "lib/ui lib " ]]; then
  ok "dirs sorted percent ascending"
else
  bad "dir sort order ($dirs)"
fi

# 2. Markdown form.
md="$("$SUMMARY" "$LCOV" "$SRC" --markdown)"
check_line "markdown file row"   "| lib/ui/c.dart | 1 | 4 | 25.0 |" "$md"
check_line "markdown dir row"    "| lib/ui | 3 | 6 | 50.0 |" "$md"
check_line "markdown never-loaded item" "- lib/util/d.dart" "$md"
if grep -q '70\.0%' <<<"$md"; then ok "markdown total"; else bad "markdown total missing"; fi
if grep -qE '^(=|-){4,}' <<<"$md"; then bad "markdown has separator noise"; else ok "no separator lines"; fi

# 3. --ext ts: never-loaded scans *.ts and skips *.test.ts and __tests__/.
TS="$SANDBOX/src"
mkdir -p "$TS/__tests__" "$TS/modules"
touch "$TS/app.ts" "$TS/modules/x.ts" "$TS/modules/x.test.ts" "$TS/__tests__/y.ts"
cat >"$SANDBOX/ts.info" <<EOF
SF:web/app.ts
DA:1,1
end_of_record
EOF
ts="$("$SUMMARY" "$SANDBOX/ts.info" "$TS" --ext ts)"
check_line "ts never-loaded module"     "never-loaded${T}web/modules/x.ts" "$ts"
check_line "ts never-loaded count"      "never-loaded-count${T}1" "$ts"
check_absent "ts test file skipped"     "x.test.ts" "$ts"
check_absent "ts __tests__ dir skipped" "__tests__" "$ts"

echo "lcov-summary: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
