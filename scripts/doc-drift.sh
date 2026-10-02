#!/usr/bin/env bash
# scripts/doc-drift.sh — two-direction doc-drift check (#1240), the fleet
# standard ported from opsurface scripts/doc-drift.sh (#229): IF THE SYSTEM CALLS
# IT, THE DOCS MUST NAME IT, and every path a doc names must exist.
#
# Direction a, "things the system calls": scripts/... paths named by
# .claude/settings.json hooks, hooks/*, .github/workflows/*, package.json, and
# every *.sh in the tree (script-to-script calls). Mentions of paths that do not
# exist are dropped: they are comments, not calls.
#
# Direction b, "paths the docs name": scripts/...{sh,mjs,py}, scripts/.../ and
# docs/...md tokens in CLAUDE.md, README.md, developer.md, SECURITY.md,
# INTEGRATION.md, docs/**/*.md, native/*.md, .claude/process.md,
# .claude/rules/*.md, .claude/agents/*.md, .claude/skills/*/SKILL.md. A token
# ending in `/` is a directory claim covering every path under it.
# native-release-notes.md is excluded: it is a changelog, history by design.
#
# CALLED-BUT-UNDOCUMENTED = a - b. DOCUMENTED-BUT-MISSING = paths in b absent on
# disk. Both pass through scripts/doc-drift-ignore.txt (globs, one per line,
# each with a comment saying why).
#
# Usage: scripts/doc-drift.sh --warn   (fast gate; always exits 0)
#        scripts/doc-drift.sh --block  (exits 1 on any finding)
#        scripts/doc-drift.sh --block --root <dir>  (test fixture override)
set -euo pipefail

MODE=""
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --warn) MODE="warn"; shift ;;
    --block) MODE="block"; shift ;;
    --root) ROOT="$2"; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "! unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$MODE" ]] || { echo "! usage: scripts/doc-drift.sh --warn|--block [--root <dir>]" >&2; exit 2; }
cd "$ROOT"

IGNORE_FILE="scripts/doc-drift-ignore.txt"
CALLED_RAW="$(mktemp)"
DOCUMENTED_RAW="$(mktemp)"
cleanup() { rm -f "$CALLED_RAW" "$CALLED_RAW.pre" "$DOCUMENTED_RAW"; }
trap cleanup EXIT

# grep exits 1 on "no matches"; under set -e that is a normal outcome here.
extract() { grep -ohP "$1" "${@:2}" 2>/dev/null || true; }

CALLED_PATTERN='scripts/[A-Za-z0-9_./-]+\.(sh|mjs|py)'
DOC_PATTERN='(scripts/[A-Za-z0-9_./-]+\.(sh|mjs|py)|scripts/[A-Za-z0-9_./-]+/|docs/[A-Za-z0-9_./-]+\.md)'

# Direction a: things the system calls.
{
  [[ -f .claude/settings.json ]] && extract "$CALLED_PATTERN" .claude/settings.json
  [[ -d hooks ]] && extract "$CALLED_PATTERN" hooks/*
  [[ -d .github/workflows ]] && extract "$CALLED_PATTERN" .github/workflows/*
  [[ -f package.json ]] && extract "$CALLED_PATTERN" package.json
  # A script naming its own path (usage header) is not a call.
  while IFS= read -r -d '' f; do
    extract "$CALLED_PATTERN" "$f" | grep -vxF "${f#./}" || true
  done < <(find . -name '*.sh' \
    -not -path './.traces/*' -not -path './.claude/worktrees/*' \
    -not -path './node_modules/*' -not -path './native/third_party/*' \
    -not -path '*/build/*' -print0)
  true
} | sort -u > "$CALLED_RAW.pre"
while IFS= read -r c; do [[ -n "$c" && -e "$c" ]] && echo "$c"; done < "$CALLED_RAW.pre" > "$CALLED_RAW" || true

# Direction b: paths the docs name.
DOC_FILES=()
for f in CLAUDE.md README.md developer.md SECURITY.md INTEGRATION.md .claude/process.md; do
  [[ -f "$f" ]] && DOC_FILES+=("$f")
done
while IFS= read -r -d '' f; do DOC_FILES+=("$f"); done < <(find docs -name '*.md' -print0 2>/dev/null)
while IFS= read -r -d '' f; do DOC_FILES+=("$f"); done < <(find native -maxdepth 1 -name '*.md' -print0 2>/dev/null)
while IFS= read -r -d '' f; do DOC_FILES+=("$f"); done < <(find .claude/rules .claude/agents -maxdepth 1 -name '*.md' -print0 2>/dev/null)
while IFS= read -r -d '' f; do DOC_FILES+=("$f"); done < <(find .claude/skills -name 'SKILL.md' -print0 2>/dev/null)

if [[ "${#DOC_FILES[@]}" -gt 0 ]]; then
  extract "$DOC_PATTERN" "${DOC_FILES[@]}" | sed 's/[.,)]*$//' | sort -u > "$DOCUMENTED_RAW"
else
  : > "$DOCUMENTED_RAW"
fi

# is_documented <path>: exact match, or a documented directory that prefixes it.
is_documented() {
  local path="$1" doc
  grep -qxF "$path" "$DOCUMENTED_RAW" && return 0
  while IFS= read -r doc; do
    [[ "$doc" == */ ]] || continue
    [[ "$path" == "$doc"* ]] && return 0
  done < "$DOCUMENTED_RAW"
  return 1
}

ignored() {
  local path="$1" pat
  [[ -f "$IGNORE_FILE" ]] || return 1
  while IFS= read -r pat; do
    [[ -z "$pat" || "$pat" == \#* ]] && continue
    # shellcheck disable=SC2053
    [[ "$path" == $pat ]] && return 0
  done < "$IGNORE_FILE"
  return 1
}

FINDINGS=0
while IFS= read -r called; do
  [[ -z "$called" ]] && continue
  ignored "$called" && continue
  if ! is_documented "$called"; then
    echo "! doc-drift: CALLED-BUT-UNDOCUMENTED: ${called}"
    FINDINGS=$((FINDINGS + 1))
  fi
done < "$CALLED_RAW"

while IFS= read -r documented; do
  [[ -z "$documented" || "$documented" == */ ]] && continue
  ignored "$documented" && continue
  if [[ ! -e "$documented" ]]; then
    echo "! doc-drift: DOCUMENTED-BUT-MISSING: ${documented}"
    FINDINGS=$((FINDINGS + 1))
  fi
done < "$DOCUMENTED_RAW"

if [[ "$FINDINGS" -eq 0 ]]; then
  echo "+ doc-drift: consistent"
  exit 0
fi
echo "! doc-drift: ${FINDINGS} finding(s)"
[[ "$MODE" == "block" ]] && exit 1
exit 0
