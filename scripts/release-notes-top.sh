#!/usr/bin/env bash
# scripts/release-notes-top.sh NOTES_FILE
#
# Prints the TOP `## ` section of a release-notes file (native-release-notes.md):
# its heading line and every line up to the next `## ` heading, trailing blank
# lines dropped. This is the "What's new" text the self-update manifest carries
# (#1258, docs/self-update.md R16). Prints nothing, exit 0, when the file is
# missing or has no section, so the caller falls back to its one-line notes.
set -euo pipefail

if [[ "$#" -ne 1 ]]; then
  echo "! usage: $0 NOTES_FILE" >&2
  exit 2
fi
[[ -f "$1" ]] || exit 0

awk '
  /^## / { if (seen) exit; seen = 1 }
  seen { lines[n++] = $0 }
  END {
    while (n > 0 && lines[n - 1] ~ /^[[:space:]]*$/) n--
    for (i = 0; i < n; i++) print lines[i]
  }
' "$1"
