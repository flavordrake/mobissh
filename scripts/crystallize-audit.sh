#!/usr/bin/env bash
# scripts/crystallize-audit.sh — Deterministic pre-pass for the crystallize skill.
#
# Scans a SKILL.md for B-bucket signal phrases (deterministic operations
# described in prose) and cross-references scripts/ for existing tools.
# Outputs a structured JSON report that the LLM uses for final A/B/C
# classification — reducing the probabilistic surface to judgment only.
#
# Usage:
#   scripts/crystallize-audit.sh --skill <path-to-SKILL.md> [--scripts-dir <dir>]
#
# Output (JSON to stdout):
#   {
#     "signal_matches": [{ "line": N, "phrase": "...", "context": "..." }],
#     "scripts_invoked": ["scripts/foo.sh", ...],
#     "scripts_available": ["scripts/bar.sh", ...],
#     "scripts_orphaned": ["scripts/baz.sh", ...],
#     "line_count": N
#   }
#
# The LLM reads this and decides: which signal_matches are real B-bucket
# (should be scripted), which are false positives (the phrase appears in
# context that's actually judgment), and which scripts_orphaned should be
# wired into the skill.

set -euo pipefail

SKILL_FILE=""
SCRIPTS_DIR="scripts"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skill) SKILL_FILE="$2"; shift 2 ;;
    --scripts-dir) SCRIPTS_DIR="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$SKILL_FILE" || ! -f "$SKILL_FILE" ]]; then
  echo "Usage: crystallize-audit.sh --skill <path-to-SKILL.md> [--scripts-dir <dir>]" >&2
  exit 1
fi

# B-bucket signal phrases — operations that should be deterministic scripts.
# Each is a case-insensitive extended regex. Ordered by specificity.
SIGNAL_PHRASES=(
  # Prose descriptions of deterministic operations
  'count (the|how many|all|each|entries|lines|files|commits|attempts)'
  'sort (by|the|them|entries|results)'
  'within the last [0-9]+ (min|hour|day|second)'
  'parse (the|each|all|JSON|YAML|TOML|output)'
  'extract (all|the|each|from)'
  'compute (the|a|an) (average|mean|sum|total|percentage|rate|count|diff)'
  'compare (the|timestamps|versions|hashes|dates)'
  'check (if|whether|that) .* (exists|matches|contains|is newer|is older|modified)'
  # Raw CLI invocations that should use wrapper scripts
  '`gh (issue|pr|api|repo) '
  '`git (log|diff|branch|show|rev-parse) '
  '`curl '
  '`docker '
  '`npm (run|test|install)'
  '`npx (tsc|vitest|playwright)'
  # Inline shell tool chains
  'stat -c'
  'wc -l'
  'jq '
  'grep .* \| .* (wc|sort|head|tail|cut|awk)'
  'date \+'
  'git log .* --since'
  'git diff --stat'
  'find \. .* -newer'
  'ls -[lt]'
)

# 1. Scan for signal phrases
MATCHES="["
FIRST=true
LINE_NUM=0
while IFS= read -r line; do
  LINE_NUM=$((LINE_NUM + 1))
  for phrase in "${SIGNAL_PHRASES[@]}"; do
    if echo "$line" | grep -qiE "$phrase" 2>/dev/null; then
      # Escape JSON special chars in context
      ESCAPED=$(echo "$line" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | head -c 200)
      PHRASE_ESCAPED=$(echo "$phrase" | sed 's/\\/\\\\/g; s/"/\\"/g')
      if [[ "$FIRST" != "true" ]]; then MATCHES+=","; fi
      MATCHES+="{\"line\":$LINE_NUM,\"phrase\":\"$PHRASE_ESCAPED\",\"context\":\"$ESCAPED\"}"
      FIRST=false
      break  # one match per line is enough
    fi
  done
done < "$SKILL_FILE"
MATCHES+="]"

# 2. Find scripts invoked by the SKILL.md
INVOKED="["
FIRST=true
while IFS= read -r script_ref; do
  if [[ "$FIRST" != "true" ]]; then INVOKED+=","; fi
  INVOKED+="\"$script_ref\""
  FIRST=false
done < <(grep -oE 'scripts/[a-z0-9_-]+\.sh' "$SKILL_FILE" | sort -u)
INVOKED+="]"

# 3. List all available scripts
AVAILABLE="["
FIRST=true
if [[ -d "$SCRIPTS_DIR" ]]; then
  while IFS= read -r script; do
    SCRIPT_NAME=$(basename "$script")
    if [[ "$FIRST" != "true" ]]; then AVAILABLE+=","; fi
    AVAILABLE+="\"scripts/$SCRIPT_NAME\""
    FIRST=false
  done < <(find "$SCRIPTS_DIR" -maxdepth 1 -name '*.sh' -type f | sort)
fi
AVAILABLE+="]"

# 4. Find orphaned scripts (available but not invoked)
ORPHANED="["
FIRST=true
if [[ -d "$SCRIPTS_DIR" ]]; then
  while IFS= read -r script; do
    SCRIPT_NAME="scripts/$(basename "$script")"
    if ! grep -q "$(basename "$script")" "$SKILL_FILE" 2>/dev/null; then
      if [[ "$FIRST" != "true" ]]; then ORPHANED+=","; fi
      ORPHANED+="\"$SCRIPT_NAME\""
      FIRST=false
    fi
  done < <(find "$SCRIPTS_DIR" -maxdepth 1 -name '*.sh' -type f | sort)
fi
ORPHANED+="]"

LINE_COUNT=$(wc -l < "$SKILL_FILE")

# Output structured JSON
cat <<ENDJSON
{
  "skill_file": "$SKILL_FILE",
  "line_count": $LINE_COUNT,
  "signal_matches": $MATCHES,
  "scripts_invoked": $INVOKED,
  "scripts_available_count": $(echo "$AVAILABLE" | grep -o '"' | wc -l | awk '{print $1/2}'),
  "scripts_orphaned": $ORPHANED
}
ENDJSON
