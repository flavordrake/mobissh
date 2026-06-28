#!/usr/bin/env bash
# scripts/notify-ntfy.sh — push a "build ready" notification via ntfy with a
# one-tap download action. BEST-EFFORT: always exits 0; never fails a build.
#
# Usage: scripts/notify-ntfy.sh "<title>" "<click/download URL>" ["<body>"]
#
# Config, first found wins:
#   env MOBISSH_NTFY_URL / MOBISSH_NTFY_TOPIC / MOBISSH_NTFY_TOKEN
#   else ~/.mobissh/ntfy.env  (NTFY_URL=, NTFY_TOPIC=, NTFY_TOKEN=)
# If URL or TOPIC is unset, logs + exits 0 (notifications simply off until set).
# The token (if any) is a secret — keep it ONLY in ntfy.env (gitignored home), never the repo.
set -uo pipefail

MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_LOGDIR"
LOGFILE="${MOBISSH_LOGDIR}/notify-ntfy.log"
log() { echo "$(date +%Y%m%dT%H%M%S%z) notify-ntfy: $*" | tee -a "$LOGFILE"; }

CFG="${HOME}/.mobissh/ntfy.env"
if [ -f "$CFG" ]; then . "$CFG"; fi

URL="${MOBISSH_NTFY_URL:-${NTFY_URL:-}}"
TOPIC="${MOBISSH_NTFY_TOPIC:-${NTFY_TOPIC:-}}"
TOKEN="${MOBISSH_NTFY_TOKEN:-${NTFY_TOKEN:-}}"

# Lead with the version (TITLE). Keep BODY informative, not obvious — the Download
# action button + Click already convey "tap to get the APK", so don't restate it.
TITLE="${1:-MobiSSH build ready}"
CLICK="${2:-}"
BODY="${3:-}"
# ntfy needs a non-empty message body; fall back to the title if none was given.
if [ -z "$BODY" ]; then BODY="$TITLE"; fi

if [ -z "$URL" ] || [ -z "$TOPIC" ]; then
  log "not configured (need URL + TOPIC; see ~/.mobissh/ntfy.env) — skipping"
  exit 0
fi

# Headers: Title, package tag, tap-to-download Click, and a Download action button.
hdrs=(-H "Title: ${TITLE}" -H "Tags: package")
if [ -n "$TOKEN" ]; then hdrs+=(-H "Authorization: Bearer ${TOKEN}"); fi
if [ -n "$CLICK" ]; then hdrs+=(-H "Click: ${CLICK}" -H "Actions: view, Download, ${CLICK}"); fi

if curl -fsS -m 15 "${hdrs[@]}" -d "${BODY}" "${URL%/}/${TOPIC}" >/dev/null; then
  log "sent '${TITLE}' → ${URL%/}/${TOPIC} (click=${CLICK:-none})"
else
  log "POST failed (best-effort; build unaffected) → ${URL%/}/${TOPIC}"
fi
exit 0
