#!/usr/bin/env bash
# scripts/mac-build-via-hub.sh — build the macOS app on the fleet Mac via the hub
# capability path, then pull the artifact back to fd-dev for publishing.
#
# Supersedes the bus-DIRECTIVE dance in dispatch-mac-build.sh: the Mac now
# publishes a `build` offer and answers `hub acquire` with a host-signed token,
# and it accepts inbound ssh — so fd-dev can drive the build directly and PULL
# the result instead of the Mac pushing it.
#
#   1. hub find   — confirm the offer is up (the Mac is a laptop: health=static,
#                   so `up` does NOT prove it is awake)
#   2. hub acquire— host-signed token, ~5min TTL. Minted by the Mac's broker, so
#                   a successful acquire IS the liveness check `find` cannot give.
#   3. ssh        — git pull + flutter build macos + ditto to a staged zip
#   4. scp        — pull the zip back to fd-dev's native-dist staging
#
# Publishing stays on fd-dev (scripts/publish-native-macos.sh) — the Mac has no
# access to native-dist/ or native.html.
#
# PATH NOTE: a non-interactive ssh gets a minimal PATH and Homebrew's bin is not
# on it, so `flutter` is "not found" despite being installed. We prepend it
# explicitly rather than depending on the Mac's shell rc.
#
# Usage: scripts/mac-build-via-hub.sh [--no-pull]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
mkdir -p "$MOBISSH_LOGDIR" "$MOBISSH_TMPDIR"
LOGFILE="${MOBISSH_LOGDIR}/mac-build-via-hub.log"
exec > >(tee -a "$LOGFILE") 2>&1

MAC_HANDLE="${MAC_HANDLE:-host@matts-macbook-air}"
MAC_OFFER="${MAC_OFFER:-mac-build}"
MAC_SSH="${MAC_SSH:-mf@matts-macbook-air.tailbe5094.ts.net}"
MAC_REPO="${MAC_REPO:-/Users/mf/code/mobissh}"
MAC_BREW_BIN="${MAC_BREW_BIN:-/opt/homebrew/bin}"
MAC_STAGE="${MAC_STAGE:-/Users/mf/mobissh-native-dist}"
LOCAL_STAGE="${LOCAL_STAGE:-${REPO_ROOT}/native-dist}"

PULL=1
[[ "${1:-}" == "--no-pull" ]] && PULL=0

log() { echo "> [mac-build] $*"; }
err() { echo "! [mac-build] $*" >&2; }

# 1. Offer present?
log "checking the mac-build offer"
if ! hub find kind=build | grep -q "$MAC_OFFER"; then
  err "no '${MAC_OFFER}' offer from ${MAC_HANDLE} — check: hub find kind=build"
  exit 1
fi

# 2. Token. This is also the real liveness probe (health=static can't tell you
# the laptop is awake; a minted token proves its broker answered).
#
# SKIP_ACQUIRE=1 proceeds on a grant already obtained in this session. Needed
# because `hub acquire` currently cannot be REPEATED: the bus rejects the second
# identical request with `duplicate_suppressed`, and tokens carry a ~5min TTL
# whose documented pattern is "re-acquire per build" — so re-acquiring is a
# duplicate by construction (reported to #fleet; varying --ttl does not help).
# Use ONLY when a token was genuinely granted for this purpose; it is not a way
# around a DENIAL.
TOKEN_FILE="${MOBISSH_TMPDIR}/mac-build-token"
if [[ "${SKIP_ACQUIRE:-0}" == "1" ]]; then
  log "SKIP_ACQUIRE=1 — proceeding on a grant already obtained this session"
else
  log "acquiring build token from ${MAC_HANDLE}"
  if ! hub acquire "$MAC_HANDLE" "$MAC_OFFER" > "$TOKEN_FILE"; then
    err "acquire failed — the Mac may be asleep/away, OR the request was"
    err "duplicate-suppressed (see #fleet). Per host@raserver: say so in #fleet"
    err "rather than retrying hard. (Infra errors here are raserver's.)"
    exit 1
  fi
  log "token acquired (~5min TTL)"
fi

# 3. Build on the Mac. Single remote script: pull, then build with an explicit
# PATH. Keep it one invocation so a dropped connection can't leave a half-build.
log "building on ${MAC_SSH} (repo ${MAC_REPO})"
REMOTE_CMD="set -euo pipefail
export PATH=${MAC_BREW_BIN}:\$PATH
export STAGE_DIR=${MAC_STAGE}
cd ${MAC_REPO}
git pull --ff-only
scripts/mac/build-native-macos.sh"

if ! ssh -o BatchMode=yes "$MAC_SSH" "$REMOTE_CMD"; then
  err "remote build FAILED — see the output above"
  exit 1
fi

if [[ "$PULL" -eq 0 ]]; then
  log "--no-pull: artifact left staged at ${MAC_SSH}:${MAC_STAGE}"
  exit 0
fi

# 4. Pull the newest zip back. The Mac now accepts inbound ssh, so fd-dev pulls
# (the old pipeline had the Mac push because Remote Login was off).
log "pulling the newest artifact back to ${LOCAL_STAGE}"
mkdir -p "$LOCAL_STAGE"
NEWEST="$(ssh -o BatchMode=yes "$MAC_SSH" "ls -t ${MAC_STAGE}/mobissh-native-macos-*.zip | head -1")"
if [[ -z "$NEWEST" ]]; then
  err "no staged zip found in ${MAC_STAGE}"
  exit 1
fi
scp -o BatchMode=yes "${MAC_SSH}:${NEWEST}" "$LOCAL_STAGE/"
log "pulled: ${LOCAL_STAGE}/$(basename "$NEWEST")"
echo
log "next: scripts/publish-native-macos.sh --from ${LOCAL_STAGE}/$(basename "$NEWEST") --version --stamp --commit --sha256"
