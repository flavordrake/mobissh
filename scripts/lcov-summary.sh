#!/usr/bin/env bash
# scripts/lcov-summary.sh — summarise an lcov.info without lcov/genhtml (#1152)
#
# fd-dev has no lcov binary, and what we need for the coverage assessment is
# not an HTML tree but three lists: per-file percent (least covered first), a
# per-directory rollup, and the NEVER-LOADED list — source files with no SF:
# record at all. lcov only reports files some test imported, so those files
# are 0% and invisible in every lcov tool; they are the prime delete-vs-cover
# candidates. Pure bash + mawk.
#
# Usage: scripts/lcov-summary.sh LCOV_FILE SRC_ROOT [--ext dart|ts] [--markdown]
#   SRC_ROOT   the source tree the lcov was collected for (native/lib or src).
#              SF: paths are matched by their suffix below SRC_ROOT's basename,
#              so relative (flutter: lib/x.dart) and absolute (vitest) records
#              both normalise to lib/x.dart or src/x.ts.
#   --ext      which files count as source for the never-loaded scan
#              (default dart). Excludes *_test.dart, *.g.dart, *.test.ts,
#              __tests__/.
#   --markdown report form instead of TSV.
#
# TSV (stdout), one record per line:
#   file<TAB>path<TAB>LH<TAB>LF<TAB>pct      percent ascending, then path
#   dir<TAB>dir<TAB>LH<TAB>LF<TAB>pct        immediate directory rollup
#   total<TAB>root<TAB>LH<TAB>LF<TAB>pct     over loaded files only
#   never-loaded<TAB>path                    sorted by path
#   never-loaded-count<TAB>N
#
# LH/LF are recomputed from DA: lines as a per-file union (a line is covered
# if any record hit it) rather than trusting the LH:/LF: fields, because a
# file can appear in more than one record and summing would double count.
set -euo pipefail

LCOV=""
SRC_ROOT=""
EXT="dart"
MARKDOWN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ext) EXT="$2"; shift 2 ;;
    --markdown) MARKDOWN=1; shift ;;
    -h|--help) sed -n '2,31p' "$0"; exit 0 ;;
    -*) echo "! unknown option: $1" >&2; exit 2 ;;
    *) if [[ -z "$LCOV" ]]; then LCOV="$1"; elif [[ -z "$SRC_ROOT" ]]; then SRC_ROOT="$1"; else echo "! too many arguments" >&2; exit 2; fi; shift ;;
  esac
done
[[ -f "$LCOV" && -d "$SRC_ROOT" ]] || { echo "usage: $0 LCOV_FILE SRC_ROOT [--ext dart|ts] [--markdown]" >&2; exit 2; }
case "$EXT" in dart|ts) ;; *) echo "! --ext must be dart or ts" >&2; exit 2 ;; esac

# Report headers show paths relative to the caller's cwd (the repo root for
# the coverage scripts) so committed reports carry no worktree-specific paths.
LCOV_DISPLAY="${LCOV#"$PWD"/}"
SRC_DISPLAY="${SRC_ROOT#"$PWD"/}"
SRC_ROOT="$(cd "$SRC_ROOT" && pwd)"
ROOT_BASE="$(basename "$SRC_ROOT")"

# Source inventory, as root-relative paths (lib/ui/x.dart), test/generated
# files excluded. Fed to awk after the lcov as a second stream.
list_sources() {
  local prune=( -path '*/__tests__' -prune -o )
  find "$SRC_ROOT" "${prune[@]}" -type f -name "*.${EXT}" \
      ! -name '*_test.dart' ! -name '*.g.dart' ! -name '*.test.ts' -print \
    | sed "s#^${SRC_ROOT}/#${ROOT_BASE}/#" | sort
}

RAW="$(mktemp "${MOBISSH_TMPDIR:-/tmp}/lcov-summary.XXXXXX")"
trap 'rm -f "$RAW"' EXIT

awk -v root="$ROOT_BASE" -v OFS='\t' '
  function pct(lh, lf) { return lf == 0 ? "100.0" : sprintf("%.1f", 100 * lh / lf) }
  function norm(p,   i) {
    # keep everything from the last "/<root>/" boundary (or a leading "<root>/")
    if (index(p, root "/") == 1) return p
    i = index(p, "/" root "/")
    if (i == 0) return ""
    return substr(p, i + 1)
  }
  FILENAME != prev { stream++; prev = FILENAME }
  stream == 1 && /^SF:/ { cur = norm(substr($0, 4)); if (cur != "") seen[cur] = 1; next }
  stream == 1 && /^DA:/ && cur != "" {
    split(substr($0, 4), a, ",")
    key = cur SUBSEP a[1]
    if (!(key in hit)) { hit[key] = 0; lf[cur]++ }
    if (a[2] + 0 > 0 && hit[key] == 0) { hit[key] = 1; lh[cur]++ }
    next
  }
  stream == 1 && /^end_of_record/ { cur = ""; next }
  stream == 2 { if (!($0 in seen)) print "never-loaded", $0; next }
  END {
    for (f in seen) {
      d = f; sub(/\/[^\/]*$/, "", d)
      print "file", f, lh[f] + 0, lf[f] + 0, pct(lh[f] + 0, lf[f] + 0)
      dlh[d] += lh[f]; dlf[d] += lf[f]; tlh += lh[f]; tlf += lf[f]; loaded++
    }
    for (d in dlf) print "dir", d, dlh[d] + 0, dlf[d], pct(dlh[d] + 0, dlf[d])
    print "total", root, tlh + 0, tlf + 0, pct(tlh + 0, tlf + 0)
    print "loaded-count", loaded + 0
  }
' "$LCOV" <(list_sources) >"$RAW"

files="$(grep '^file' "$RAW" | sort -t $'\t' -k5,5n -k2,2)"
dirs="$(grep '^dir' "$RAW" | sort -t $'\t' -k5,5n -k2,2)"
total="$(grep '^total' "$RAW")"
never="$(grep '^never-loaded' "$RAW" | sort -t $'\t' -k2,2 || true)"
never_count="$(grep -c '^never-loaded' "$RAW" || true)"
loaded_count="$(grep '^loaded-count' "$RAW" | cut -f2)"

if [[ "$MARKDOWN" -eq 0 ]]; then
  [[ -n "$files" ]] && printf '%s\n' "$files"
  [[ -n "$dirs" ]] && printf '%s\n' "$dirs"
  printf '%s\n' "$total"
  [[ -n "$never" ]] && printf '%s\n' "$never"
  printf 'never-loaded-count\t%s\n' "$never_count"
  exit 0
fi

IFS=$'\t' read -r _ _ tlh tlf tpct <<<"$total"
echo "# Coverage: ${ROOT_BASE} (${SRC_DISPLAY})"
echo
echo "Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) from ${LCOV_DISPLAY}"
echo
echo "Total: ${tpct}% (${tlh}/${tlf} lines) over ${loaded_count} loaded files; ${never_count} source files never loaded by any test (0%, not in the total)."
echo
echo "## Files, least covered first"
echo
echo "| file | LH | LF | % |"
echo "|---|---|---|---|"
[[ -n "$files" ]] && awk -F'\t' '{ print "| " $2 " | " $3 " | " $4 " | " $5 " |" }' <<<"$files"
echo
echo "## Directories"
echo
echo "| directory | LH | LF | % |"
echo "|---|---|---|---|"
[[ -n "$dirs" ]] && awk -F'\t' '{ print "| " $2 " | " $3 " | " $4 " | " $5 " |" }' <<<"$dirs"
echo
echo "## Never loaded (${never_count})"
echo
[[ -n "$never" ]] && awk -F'\t' '{ print "- " $2 }' <<<"$never"
exit 0
