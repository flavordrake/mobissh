#!/usr/bin/env bash
# scripts/backlog-close-batch.sh — close a list of issues with a cited comment,
# for backlog reconciliation. Input file: one "NUMBER|REASON" per line (blank
# lines and #-comments skipped). Each close routes through gh-ops.sh so the
# close is audit-logged; the comment cites the ground-truth reason and invites
# reopen, so the sweep is fully reversible.
#
# Usage: scripts/backlog-close-batch.sh <list-file>
set -euo pipefail
cd "$(dirname "$0")/.."

LIST="${1:?usage: backlog-close-batch.sh <list-file>}"
[ -f "$LIST" ] || { echo "! no such list file: $LIST" >&2; exit 2; }

closed=0
failed=0
while IFS='|' read -r num reason; do
  # Skip blanks / comments.
  case "$num" in ''|\#*) continue ;; esac
  num="${num//[[:space:]]/}"
  reason="${reason#"${reason%%[![:space:]]*}"}" # ltrim
  comment="Closing during backlog reconciliation (2026-07-18): ${reason} — reopen if this is wrong."
  if scripts/gh-ops.sh close "$num" --comment "$comment"; then
    closed=$((closed + 1))
  else
    echo "! failed to close #${num}" >&2
    failed=$((failed + 1))
  fi
done < "$LIST"

echo "+ backlog-close: closed ${closed}, failed ${failed}"
