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
#     [path ...]                      files to stage. If omitted, stages
#                                     modified tracked files (git add -u) PLUS
#                                     new files under native/ (git add native/),
#                                     so new source ships AND lands in git.
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

# Bump the build number (version: X.Y.Z+N → +N+1) so a ship can never go out
# self-reporting the previous version (happened on +56: pubspec was passed but
# never edited, so the binary reported +55).
#
# The SEMVER and the BUILD NUMBER are INDEPENDENT. This used to skip the bump
# whenever pubspec was dirty, on the theory that a dirty file meant a deliberate
# manual bump. But every release hand-edits the semver, which dirties the file,
# which silently froze the build number: v0.1.11 shipped as +162, reusing the
# Android versionCode already spent by 0.1.10+162, while the commit message
# claimed +163. versionCode must STRICTLY INCREASE for Play (#966), and a repeat
# makes in-place upgrade ambiguous for sideloads.
#
# So: respect a manual BUILD edit, always bump when only the semver moved.
# The decision lives in scripts/lib/next-build-version.sh so it can be tested
# without running a build (scripts/test-next-build-version.sh).
PUBSPEC="native/pubspec.yaml"
source "$(dirname "$0")/lib/next-build-version.sh"
read_version() { grep -E '^version:' | head -1 | awk '{print $2}'; }

CUR_VERSION="$(read_version < "$PUBSPEC")"
HEAD_VERSION="$(git show "HEAD:${PUBSPEC}" | read_version)"

if ! NEW_VERSION="$(next_build_version "$CUR_VERSION" "$HEAD_VERSION")"; then
  echo "! ship-native: refusing to ship — versionCode must strictly increase (Play, #966)." >&2
  exit 2
fi

if [[ "$NEW_VERSION" == "$CUR_VERSION" ]]; then
  echo "> respecting manual build number: ${CUR_VERSION}"
else
  sed -i "s/^version: .*/version: ${NEW_VERSION}/" "$PUBSPEC"
  if [[ "${CUR_VERSION%+*}" != "${HEAD_VERSION%+*}" ]]; then
    echo "> semver manually bumped to ${CUR_VERSION%+*}; build auto-bumped: ${HEAD_VERSION} → ${NEW_VERSION}"
  else
    echo "> auto-bumped version: ${CUR_VERSION} → ${NEW_VERSION}"
  fi
fi

if [ "${#PATHS[@]}" -gt 0 ]; then
  echo "> staging ${#PATHS[@]} path(s): ${PATHS[*]}"
  git add -- "${PATHS[@]}" "$PUBSPEC"
else
  # `git add -u` catches modified TRACKED files anywhere (e.g. the root-level
  # native-release-notes.md); `git add native/` additionally stages NEW
  # untracked source/test files under native/ (gitignored build output is still
  # excluded). Without the second add, new files shipped in the APK (built from
  # the working tree) but were never committed — leaving dangling imports on
  # main (#962/#559 fallout).
  echo "> staging modified tracked files (git add -u) + new native/ files"
  git add -u
  git add native/
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
