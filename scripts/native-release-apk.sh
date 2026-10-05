#!/usr/bin/env bash
# scripts/native-release-apk.sh — Build + publish the native release APK.
#
# Captures the recurring delivery ritual (memory: feedback_apk_timestamp):
#   1. flutter build apk --release (signed with the release keystore — see
#      memory native-android-signing; REFUSES to build if key.properties is
#      missing, #1215), with --dart-define=MOBISSH_BUILD=<B>. REFUSES when the
#      active Flutter is not the one pinned in native/.flutter-version (#1277).
#   2. Copy to public/mobissh-native-<ISO-8601-ts>.apk AND the stable
#      public/mobissh-native.apk alias.
#   3. docker cp BOTH into mobissh-prod:/app/public/ so the running container
#      serves them immediately (the build caches the public/ COPY layer, so a
#      container rebuild would NOT pick up a new APK — copy directly).
#   4. Print the timestamped download URL to quote to the user.
#   5. Write native-dist/android-latest.json (self-update manifest, #1215) last.
#
# Run from the repo root. Exit 0 = published, 2 = build/setup error.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"
LOGFILE="${MOBISSH_LOGDIR}/native-release-apk.log"
exec > >(tee -a "$LOGFILE") 2>&1

# #1215 R4: refuse to build without the release keystore. Without key.properties
# gradle emits an UNSIGNED release (#1277; it used to be DEBUG-signed), which can
# never upgrade an installed release copy and the in-app updater refuses it
# (signing-cert match, docs/self-update.md R10). Same path gradle reads.
KEY_PROPS="${MOBISSH_KEY_PROPERTIES:-/home/dev/.mobissh-android/key.properties}"
if [[ ! -f "$KEY_PROPS" ]]; then
  echo "! FATAL: release keystore config missing (${KEY_PROPS})." >&2
  echo "  Without it the APK is unsigned and cannot upgrade installed copies. Aborting." >&2
  exit 2
fi
echo "> release keystore config: ${KEY_PROPS}"

NATIVE_DIR="${REPO_ROOT}/native"
PUBLIC_DIR="${REPO_ROOT}/public"
PROD_CONTAINER="mobissh-prod"
PROD_PUBLIC="/app/public"
SERVE_HOST="https://mobissh.tailbe5094.ts.net"
# #dx: --split-per-abi builds one small single-ABI APK per architecture instead
# of one fat ~91MB APK with all three. arm64-v8a (every modern phone) is the
# PRIMARY published download (~30MB → ~3x faster download + install); the
# armeabi-v7a / x86_64 splits are published as fallbacks for other devices.
APK_DIR="${NATIVE_DIR}/build/app/outputs/flutter-apk"
BUILT_APK="${APK_DIR}/app-arm64-v8a-release.apk"
FALLBACK_V7A="${APK_DIR}/app-armeabi-v7a-release.apk"
FALLBACK_X64="${APK_DIR}/app-x86_64-release.apk"
# Persistent, bind-mounted native distribution dir (#700). docker-compose.prod.yml
# mounts this host path at the container's /app/native-dist, and server/index.js
# serves the native artifact names from there — so the APK + install page survive
# a container recreate AND the `container-ctl.sh push` hot-cp of public/ (the old
# docker-cp-into-/app/public approach was wiped by both). FIXED host path (the main
# checkout, = the mounted volume), independent of which worktree built the APK.
NATIVE_DIST_HOST="${NATIVE_DIST_HOST:-/home/dev/workspace/mobissh/native-dist}"

TS="$(date +%Y%m%dT%H%M%S%z)"
# Embed the app version (e.g. 0.1.10+117) in the published filename so a downloaded
# APK is SELF-IDENTIFYING — it matches exactly what the app shows in Settings/
# feedback. Was timestamp-only, which made builds indistinguishable once downloaded
# (the owner couldn't tell +116 from +117). The `+` is path-safe: $TS already
# carries one (the `+0000` tz offset) and serves fine. The timestamp stays for
# uniqueness (two ships on the same build number can't overwrite each other).
extract_version() { grep -E '^version:' "${NATIVE_DIR}/pubspec.yaml" | head -1 | awk '{print $2}' || true; }
APP_VERSION="$(extract_version)"
APP_VERSION="${APP_VERSION:-unknown}"
STAMPED="mobissh-native-${APP_VERSION}-${TS}.apk"
STABLE="mobissh-native.apk"
# The commit the APK is built from — passed to the page generator so the page's
# displayed hash ALWAYS matches the binary (never live HEAD on a page-only regen).
BUILD_COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"

log() { echo "> $*"; }
err() { echo "! $*" >&2; }

# #1215 R2: bake the exact build ordinal B (x.y.z[-STAGE]+B) into the app so the
# self-updater compares integers, not the split-per-abi versionCode decoding
# (`% 1000`), which breaks at B=1000.
BUILD_NUMBER="${APP_VERSION##*+}"
if [[ "$APP_VERSION" != *+* || ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  err "pubspec version has no integer build ordinal: ${APP_VERSION}"
  exit 2
fi

# Feedback upload auth (#484/#1115): bake the shared X-MobiSSH-Key into the
# build so bug reports keep working once prod fails closed. The key is NOT a
# confidential secret (it can be extracted from any APK), but it still never goes
# on a command line or into a log (#1277): it reaches flutter only through
# --dart-define-from-file. Sources, first match wins:
#   MOBISSH_BUILD_INPUTS=<file.json>  {"MOBISSH_FEEDBACK_KEY": "..."} (homelab#44 builder)
#   FEEDBACK_KEY in the environment, else ~/.mobissh/feedback.env (today's local ships)
# Either way the inputs are re-staged as a 0600 JSON INSIDE native/, passed by a
# relative path: the buildbox route snapshots the repo, so a /tmp path would not
# exist there. Deleted after the build (EXIT trap covers failures).
# A missing key FAILS CLOSED; MOBISSH_ALLOW_NO_FEEDBACK_KEY=1 opts out, -dev only.
DEFINES=("--dart-define=MOBISSH_BUILD=${BUILD_NUMBER}")
FEEDBACK_ENV="${HOME}/.mobissh/feedback.env"
BUILD_INPUTS="${MOBISSH_BUILD_INPUTS:-}"
if [[ -z "$BUILD_INPUTS" && -z "${FEEDBACK_KEY:-}" && -f "$FEEDBACK_ENV" ]]; then
  # shellcheck disable=SC1090
  . "$FEEDBACK_ENV"
fi
# Exit 3 = no MOBISSH_FEEDBACK_KEY, 4 = unreadable inputs. Prints nothing: an
# exception message could quote the file.
STAGE_INPUTS_PY='
import json, os, sys
dest, src = sys.argv[1], sys.argv[2]
if src:
    try:
        with open(src, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        sys.exit(4)
    if not isinstance(data, dict) or not all(
            isinstance(v, (str, int, float, bool)) for v in data.values()):
        sys.exit(4)
else:
    data = {"MOBISSH_FEEDBACK_KEY": os.environ.get("FEEDBACK_KEY", "")}
key = data.get("MOBISSH_FEEDBACK_KEY")
if not isinstance(key, str) or not key:
    sys.exit(3)
with open(dest, "w", encoding="utf-8") as f:
    json.dump(data, f)
'
STAGED_INPUTS=""
if [[ -n "$BUILD_INPUTS" || -n "${FEEDBACK_KEY:-}" ]]; then
  STAGED_INPUTS="$(mktemp --suffix=.json "${NATIVE_DIR}/.build-inputs.XXXXXXXX")"   # mktemp creates it 0600
  trap 'rm -f "$STAGED_INPUTS"' EXIT
  stage_rc=0
  FEEDBACK_KEY="${FEEDBACK_KEY:-}" python3 -c "$STAGE_INPUTS_PY" "$STAGED_INPUTS" "$BUILD_INPUTS" || stage_rc=$?
  if [[ $stage_rc -eq 3 ]]; then
    err "build inputs carry no MOBISSH_FEEDBACK_KEY (${BUILD_INPUTS:-$FEEDBACK_ENV}); refusing the release"
    exit 2
  elif [[ $stage_rc -ne 0 ]]; then
    err "build inputs unreadable (${BUILD_INPUTS}): want a JSON object of string/number/bool values; refusing the release"
    exit 2
  fi
  DEFINES+=("--dart-define-from-file=${STAGED_INPUTS##*/}")
  log "feedback key: staged for --dart-define-from-file (value not logged)"
elif [[ "${MOBISSH_ALLOW_NO_FEEDBACK_KEY:-}" == 1 && "$APP_VERSION" == *-dev+* ]]; then
  err "WARNING: building WITHOUT a feedback key (MOBISSH_ALLOW_NO_FEEDBACK_KEY=1, -dev build):"
  err "  bug reports from this build are rejected by prod (#1115)."
else
  err "no feedback key: set MOBISSH_BUILD_INPUTS or provide ${FEEDBACK_ENV} (FEEDBACK_KEY=...)."
  if [[ "${MOBISSH_ALLOW_NO_FEEDBACK_KEY:-}" == 1 ]]; then
    err "  MOBISSH_ALLOW_NO_FEEDBACK_KEY applies to -dev builds only, not ${APP_VERSION}."
  fi
  err "  A keyless build cannot file bug reports against prod (#1115). Refusing the release."
  exit 2
fi

# #1277: the release is built with the Flutter SDK pinned in native/.flutter-version
# and nothing else. `--version` is not routed to the buildbox, so this checks the
# fd-dev SDK; the buildbox image pins its own (3.44.0 today) and the isolated
# builder (homelab#44) is expected to read this same file.
FLUTTER_PIN_FILE="${NATIVE_DIR}/.flutter-version"
if [[ ! -f "$FLUTTER_PIN_FILE" ]]; then
  err "pinned Flutter version missing (${FLUTTER_PIN_FILE}); refusing an unpinned release"
  exit 2
fi
FLUTTER_PIN="$(tr -d '[:space:]' < "$FLUTTER_PIN_FILE")"
FLUTTER_ACTIVE="$("${REPO_ROOT}/scripts/flutter-cmd.sh" --version --machine | sed -n 's/.*"frameworkVersion": *"\([^"]*\)".*/\1/p' | head -1 || true)"
if [[ -z "$FLUTTER_PIN" || "$FLUTTER_ACTIVE" != "$FLUTTER_PIN" ]]; then
  err "active Flutter ${FLUTTER_ACTIVE:-<unknown>} != pinned ${FLUTTER_PIN:-<empty>} (native/.flutter-version); refusing the release"
  exit 2
fi
log "flutter ${FLUTTER_ACTIVE} matches native/.flutter-version"

# #1277: the release must resolve exactly the hashes pinned in pubspec.lock.
# `--enforce-lockfile` refuses a lockfile that pubspec.yaml no longer matches and
# any package whose sha256 differs from the lock. `pub get` is not routed to the
# buildbox, so this checks the committed lock here; the buildbox's implicit pub
# get inside `build apk` cannot take the flag (homelab runner change, #1277).
log "verifying Dart dependencies against pubspec.lock (--enforce-lockfile)"
if ! "${REPO_ROOT}/scripts/flutter-cmd.sh" --in "$NATIVE_DIR" pub get --enforce-lockfile; then
  err "flutter pub get --enforce-lockfile failed: pubspec.lock is stale or a package hash does not match"
  exit 2
fi

log "building native release APK (this can take a few minutes)..."
if ! "${REPO_ROOT}/scripts/flutter-cmd.sh" --in "$NATIVE_DIR" build apk --release --split-per-abi ${DEFINES[@]+"${DEFINES[@]}"}; then
  err "flutter build apk --release --split-per-abi failed"
  exit 2
fi
if [[ -n "$STAGED_INPUTS" ]]; then rm -f "$STAGED_INPUTS"; fi

if [[ ! -f "$BUILT_APK" ]]; then
  err "expected arm64 APK not found at $BUILT_APK"
  exit 2
fi

# #1271: outputs can come back from a remote builder with symlinks intact, and
# `[[ -f ]]` / `cp` follow them, so a symlinked "APK" would publish its target
# (key.properties, the keystore, feedback.env) on the tailnet. Check every APK
# BEFORE the first copy so a refused build publishes nothing at all.
require_regular_apk() {
  if [[ -L "$1" || ! -f "$1" ]]; then
    err "refusing to publish ${1}: not a regular file (symlink?)"
    exit 2
  fi
}
require_regular_apk "$BUILT_APK"
for apk in "$FALLBACK_V7A" "$FALLBACK_X64"; do
  if [[ -e "$apk" || -L "$apk" ]]; then require_regular_apk "$apk"; fi
done

log "publishing to ${PUBLIC_DIR}/ as ${STAMPED} + ${STABLE}"
cp "$BUILT_APK" "${PUBLIC_DIR}/${STAMPED}"
cp "$BUILT_APK" "${PUBLIC_DIR}/${STABLE}"

log "generating stable install landing page (public/native.html)"
"${REPO_ROOT}/scripts/gen-apk-install-page.sh" "$TS" "$STABLE" "$STAMPED" "$BUILD_COMMIT"

# Publish into the PERSISTENT bind-mounted native-dist (#700) — NOT docker cp into
# /app/public (which a recreate or public hot-push wipes). The container sees these
# immediately via the /app/native-dist mount, and they survive restarts.
log "publishing APKs + install page into ${NATIVE_DIST_HOST}/ (persistent, live-served)"
mkdir -p "$NATIVE_DIST_HOST"
# `cp -f` with --remove-destination, NOT a bare cp: public/ and native-dist/
# entries can be HARDLINKS to the same inode (same device, and something has
# linked rather than copied them before). A bare `cp A B` on one inode fails
# "are the same file" and, under `set -e`, aborts the publish MID-WAY — on
# 2026-09-23 that shipped +190's APK while leaving native.html at +189, so the
# install page advertised the old build with the new binary beside it.
publish_to_dist() {
  local src="$1" dest="$2"
  if [[ "$src" -ef "$dest" ]]; then
    echo "> (${dest##*/} is already the same inode as the source — nothing to copy)"
    return 0
  fi
  cp -f --remove-destination "$src" "$dest"
}
publish_to_dist "${PUBLIC_DIR}/${STAMPED}" "${NATIVE_DIST_HOST}/${STAMPED}"
publish_to_dist "${PUBLIC_DIR}/${STABLE}" "${NATIVE_DIST_HOST}/${STABLE}"
publish_to_dist "${PUBLIC_DIR}/native.html" "${NATIVE_DIST_HOST}/native.html"
publish_to_dist "${PUBLIC_DIR}/native-time.js" "${NATIVE_DIST_HOST}/native-time.js"
publish_to_dist "${PUBLIC_DIR}/native-feedback.js" "${NATIVE_DIST_HOST}/native-feedback.js"

# Fallback splits for non-arm64 devices (best-effort; published but not the
# primary install link). The server's native-dist regex serves these names too.
STAMPED_V7A="mobissh-native-${APP_VERSION}-${TS}-armeabi-v7a.apk"
STAMPED_X64="mobissh-native-${APP_VERSION}-${TS}-x86_64.apk"
if [[ -f "$FALLBACK_V7A" ]]; then
  cp "$FALLBACK_V7A" "${NATIVE_DIST_HOST}/${STAMPED_V7A}"
fi
if [[ -f "$FALLBACK_X64" ]]; then
  cp "$FALLBACK_X64" "${NATIVE_DIST_HOST}/${STAMPED_X64}"
fi

# #1215 R1: the self-update manifest goes LAST, once the APK it names is in
# place. sha256 is of the published stamped arm64 file; written atomically.
# Notes: the top section of native-release-notes.md (#1258, the app's "What's
# new"), else the ship commit's subject (ship-native.sh commits, then execs us).
# An explicit MOBISSH_RELEASE_NOTES wins over both.
RELEASE_NOTES="${MOBISSH_RELEASE_NOTES:-$(git -C "$REPO_ROOT" log -1 --format=%s)}"
NOTES_FILE="${REPO_ROOT}/native-release-notes.md"
if [[ -n "${MOBISSH_RELEASE_NOTES:-}" ]]; then NOTES_FILE=""; fi
log "writing ${NATIVE_DIST_HOST}/android-latest.json"
"${REPO_ROOT}/scripts/gen-android-latest-json.sh" \
  "$NATIVE_DIST_HOST" "$STAMPED" "$APP_VERSION" "$SERVE_HOST" "$RELEASE_NOTES" \
  "$NOTES_FILE"

echo "+ PUBLISHED"
echo "+ install page (bookmark this, refresh for latest):"
echo "  ${SERVE_HOST}/native.html"
echo "+ stable apk:  ${SERVE_HOST}/${STABLE}"
echo "+ this build:  ${SERVE_HOST}/${STAMPED}"

# Announce on the fleet bus. ntfy is RETIRED for operator alerts (fleet ONE-BUS
# RULE: Matrix only) and its push had been silently no-opping — two builds
# shipped with nobody told before it was caught (#1104). notify-build.sh fails
# LOUD + non-zero rather than "skipping", so an unannounced build is impossible
# to miss. The artifact URLs are already printed above, so nothing is lost if
# this step is the thing that fails.
BUILD_VERSION="$(grep -E '^version:' "${NATIVE_DIR}/pubspec.yaml" | awk '{print $2}')"
"${REPO_ROOT}/scripts/notify-build.sh" "${BUILD_VERSION}" "${SERVE_HOST}/${STAMPED}"
