#!/usr/bin/env bash
# scripts/notify-build.sh — announce a published build on the fleet bus (hub).
#
# Replaces notify-ntfy.sh for build pushes. ntfy is RETIRED for operator alerts
# under the fleet's pinned ONE-BUS RULE: "Matrix is the ONLY comms system for
# notification + direction." The ntfy path silently no-opped (bridge unset ->
# "skipping", exit 0), so builds shipped with nobody told — twice in a row
# before it was noticed (#1104).
#
# LOUD BY DESIGN: if the announcement cannot be delivered this exits NON-ZERO
# and prints the manual command. A build nobody hears about has not, from the
# operator's point of view, shipped — so a failure here must never be a quiet
# `skipping` again.
#
# Usage: notify-build.sh <version> <url> [extra-line...]
#   version  e.g. 0.1.10+162        (leads the subject — the operator scans this)
#   url      the timestamped artifact URL, printed on its OWN line
#   extra    optional additional body lines (changelog one-liners)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_LOGDIR"
LOGFILE="${MOBISSH_LOGDIR}/notify-build.log"
exec > >(tee -a "$LOGFILE") 2>&1

CHANNEL="${HUB_BUILD_CHANNEL:-#fleet}"   # #alerts needs coordinator power; #fleet is ours

if [[ $# -lt 2 ]]; then
  echo "! notify-build: usage: notify-build.sh <version> <url> [extra-line...]" >&2
  exit 2
fi

VERSION="$1"; shift
URL="$1"; shift

# URLs on their own line (operator preference) and tailnet-only per the fleet's
# URL-hygiene pin — never .lan / 192.168.x.
BODY="BUILD ${VERSION} (MobiSSH native, Android)
${URL}"
for line in "$@"; do
  [[ -n "$line" ]] && BODY="${BODY}
${line}"
done

loud_fail() {
  echo "!"
  echo "! ================================================================"
  echo "! BUILD PUBLISHED BUT NOT ANNOUNCED — nobody has been told."
  echo "! reason: $1"
  echo "!"
  echo "! Announce it manually:"
  echo "!   hub send \"${CHANNEL}\" \"BUILD ${VERSION} — ${URL}\" -s \"BUILD ${VERSION}\""
  echo "! ================================================================"
  echo "!"
}

if ! command -v hub >/dev/null 2>&1; then
  loud_fail "the 'hub' CLI is not on PATH (expected ~/.local/bin/hub)"
  exit 1
fi

if hub send "$CHANNEL" "$BODY" -s "BUILD ${VERSION} MobiSSH native"; then
  echo "+ notify-build: announced ${VERSION} on ${CHANNEL}"
else
  loud_fail "hub send to ${CHANNEL} failed (see the error above)"
  exit 1
fi
