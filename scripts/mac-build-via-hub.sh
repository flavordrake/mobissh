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
# The token is ENFORCED at point-of-use: the Mac's shim rejects a build without
# RELAYGENT_CAPTOKEN ("DENY: build access requires a capability token"). It was
# advisory when this script was first written and is not any more — so we must
# both obtain it AND pass it into the remote environment.
#
# CAPTOKEN=<token> reuses a grant obtained out-of-band. Needed because `hub
# acquire` is duplicate-suppressed within a time window, so a re-acquire shortly
# after a previous identical request is rejected even though the grant is
# legitimate (reported to #fleet). It is NOT a way around a denial — without a
# valid token the Mac refuses the build regardless.
TOKEN_FILE="${MOBISSH_TMPDIR}/mac-build-token"
if [[ -n "${CAPTOKEN:-}" ]]; then
  log "using a capability token supplied via CAPTOKEN"
  printf '%s' "$CAPTOKEN" > "$TOKEN_FILE"
else
  log "acquiring build token from ${MAC_HANDLE}"
  if ! hub acquire "$MAC_HANDLE" "$MAC_OFFER" > "$TOKEN_FILE"; then
    err "acquire failed — the Mac may be asleep/away, OR the request was"
    err "duplicate-suppressed within the dedupe window (see #fleet). Retry later,"
    err "or pass a grant via CAPTOKEN=<token>. Per host@raserver: say so in #fleet"
    err "rather than retrying hard. (Infra errors here are raserver's.)"
    exit 1
  fi
  log "token acquired (~5min TTL)"
fi
TOKEN="$(cat "$TOKEN_FILE")"
if [[ -z "$TOKEN" ]]; then
  err "empty capability token — refusing to attempt a build that will be DENYed"
  exit 1
fi

# 3. Build on the Mac. Single remote script: pull, then build with an explicit
# PATH. Keep it one invocation so a dropped connection can't leave a half-build.
log "building on ${MAC_SSH} (repo ${MAC_REPO})"
# The token must PREFIX the command, exactly as the shim's own DENY message shows
# (`ssh ... "RELAYGENT_CAPTOKEN=$TOK <build cmd>"`). A forced command inspects the
# command STRING, so an `export RELAYGENT_CAPTOKEN=...` inside the script body is
# invisible to it and still gets DENYed — the assignment has to be the first thing
# on the line. Single quotes around the inner script are safe: it contains none,
# and $PATH must expand REMOTELY, not here.
REMOTE_SCRIPT="set -euo pipefail; export PATH=${MAC_BREW_BIN}:\$PATH; export STAGE_DIR=${MAC_STAGE}; cd ${MAC_REPO}; git pull --ff-only; scripts/mac/build-native-macos.sh"
REMOTE_CMD="RELAYGENT_CAPTOKEN=${TOKEN} bash -c '${REMOTE_SCRIPT}'"

if ! ssh -o BatchMode=yes "$MAC_SSH" "$REMOTE_CMD"; then
  err "remote build FAILED — see the output above"
  exit 1
fi

if [[ "$PULL" -eq 0 ]]; then
  log "--no-pull: artifact left staged at ${MAC_SSH}:${MAC_STAGE}"
  exit 0
fi

# 4. Locate the artifact. The Mac's own build script PUSHES to fd-dev when
# FDDEV_DEST is set, so in the normal case it has already arrived and there is
# nothing to pull — two delivery paths for one file, which is how you eventually
# publish a half-written artifact. Prefer the pushed copy.
#
# Pulling is also gated: the capability shim applies to EVERY ssh command on this
# host, not just the build, so a bare `ls` over ssh is DENYed without the token
# prefix (that is what made this step exit 77 while the build itself succeeded).
PUSHED_DIR="${PUSHED_DIR:-$HOME/mobissh-native-dist}"
NEWEST_LOCAL="$(ls -t "${PUSHED_DIR}"/mobissh-native-macos-*.zip 2>/dev/null | head -1 || true)"

if [[ -n "$NEWEST_LOCAL" ]]; then
  log "artifact already delivered by the Mac's push: ${NEWEST_LOCAL}"
  ARTIFACT="$NEWEST_LOCAL"
else
  log "no pushed artifact — pulling from ${MAC_SSH}"
  mkdir -p "$LOCAL_STAGE"
  NEWEST="$(ssh -o BatchMode=yes "$MAC_SSH" "RELAYGENT_CAPTOKEN=${TOKEN} ls -t ${MAC_STAGE}/mobissh-native-macos-*.zip | head -1")"
  if [[ -z "$NEWEST" ]]; then
    err "no staged zip found in ${MAC_STAGE}"
    exit 1
  fi
  scp -o BatchMode=yes "${MAC_SSH}:${NEWEST}" "$LOCAL_STAGE/"
  ARTIFACT="${LOCAL_STAGE}/$(basename "$NEWEST")"
  log "pulled: ${ARTIFACT}"
fi

echo
log "next: scripts/publish-native-macos.sh --from ${ARTIFACT} --version --stamp --commit --sha256"
log "(the build output above prints the exact --version/--stamp/--commit/--sha256 to use)"
