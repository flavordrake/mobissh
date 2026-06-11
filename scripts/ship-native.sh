#!/usr/bin/env bash
# scripts/ship-native.sh — commit + push + build/publish the native APK, one step.
#
# Captures the orchestrator's native ship ritual (stage → commit → push →
# native-release-apk) so it stops being hand-rolled raw `git` (which drifts CWD).
# Always runs from the repo root (cd via its own dirname), so a drifted process
# CWD can't break it.
#
# Usage:
#   scripts/ship-native.sh --message-file FILE [path ...]
#     --message-file FILE | -F FILE   commit message file (create it with the
#                                     Write tool; end it with the Co-Authored-By
#                                     trailer). REQUIRED.
#     [path ...]                      files to stage. If omitted, stages all
#                                     MODIFIED TRACKED files (git add -u) — never
#                                     untracked junk.
#
# Gate FIRST (scripts/native-fast-gate.sh) — this script does NOT gate.
# Prints the timestamped install URL on success (via native-release-apk.sh).

set -euo pipefail
cd "$(dirname "$0")/.."

MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"
LOGFILE="${MOBISSH_LOGDIR}/ship-native.log"
exec > >(tee -a "$LOGFILE") 2>&1

MSG_FILE=""
PATHS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --message-file|-F)
      MSG_FILE="${2:-}"
      shift 2
      ;;
    *)
      PATHS+=("$1")
      shift
      ;;
  esac
done

if [ -z "$MSG_FILE" ]; then
  echo "! ship-native: --message-file FILE is required" >&2
  exit 2
fi
if [ ! -f "$MSG_FILE" ]; then
  echo "! ship-native: message file not found: $MSG_FILE" >&2
  exit 2
fi

# Auto-bump the build number (version: X.Y.Z+N → +N+1) so a ship can never go
# out self-reporting the previous version (happened on +56: pubspec was passed
# but never edited, so the binary reported +55). If pubspec.yaml already has an
# UNCOMMITTED version change (a deliberate manual bump, e.g. a minor-version
# jump), respect it and skip the auto-bump.
PUBSPEC="native/pubspec.yaml"
if git diff --quiet HEAD -- "$PUBSPEC"; then
  CUR_VERSION="$(grep -E '^version:' "$PUBSPEC" | head -1 | awk '{print $2}')"
  BASE="${CUR_VERSION%+*}"
  BUILD="${CUR_VERSION##*+}"
  if [[ "$CUR_VERSION" == *+* && "$BUILD" =~ ^[0-9]+$ ]]; then
    NEW_VERSION="${BASE}+$((BUILD + 1))"
    sed -i "s/^version: .*/version: ${NEW_VERSION}/" "$PUBSPEC"
    echo "> auto-bumped version: ${CUR_VERSION} → ${NEW_VERSION}"
  else
    echo "! ship-native: cannot parse build number in '${CUR_VERSION}' — bump manually" >&2
    exit 2
  fi
else
  echo "> pubspec.yaml already modified (manual bump) — keeping it as-is"
fi

if [ "${#PATHS[@]}" -gt 0 ]; then
  echo "> staging ${#PATHS[@]} path(s): ${PATHS[*]}"
  git add -- "${PATHS[@]}" "$PUBSPEC"
else
  echo "> staging all modified tracked files (git add -u)"
  git add -u
fi

if git diff --cached --quiet; then
  echo "! ship-native: nothing staged to commit — aborting" >&2
  exit 1
fi

echo "> committing"
git commit -F "$MSG_FILE"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
echo "> pushing $BRANCH → origin"
git push origin "$BRANCH"

echo "> building + publishing native APK"
exec ./scripts/native-release-apk.sh
