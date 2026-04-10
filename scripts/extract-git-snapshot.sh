#!/usr/bin/env bash
# Extract a file from a specific git commit to a destination path.
# Usage: scripts/extract-git-snapshot.sh <commit> <git-path> <dest-path>
set -euo pipefail

COMMIT="${1:?Usage: extract-git-snapshot.sh <commit> <git-path> <dest-path>}"
GIT_PATH="${2:?Missing git-path}"
DEST="${3:?Missing dest-path}"

mkdir -p "$(dirname "$DEST")"
git show "${COMMIT}:${GIT_PATH}" > "$DEST"
echo "Extracted ${COMMIT}:${GIT_PATH} → ${DEST} ($(wc -l < "$DEST") lines)"
