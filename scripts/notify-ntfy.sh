#!/usr/bin/env bash
# scripts/notify-ntfy.sh — push a "build ready" (or any release/test cycle)
# notification with a one-tap open action. BEST-EFFORT: always exits 0; never
# fails a build.
#
# Usage: scripts/notify-ntfy.sh "<title>" "<click/open URL>" ["<body>"] ["<stage>"]
#   stage defaults to "build-ready" (e.g. build-ready | test-ready | release).
#
# Two transports, first that is configured + succeeds wins:
#   1. BRIDGE (preferred): agent-hub notify bridge. We present the mobissh-ci
#      WRITER JWT; the hub validates it and publishes to ntfy with a server-held
#      token — this box never holds a native ntfy token. This is the #dx path the
#      403-saga resolved to (stock ntfy rejects the writer JWT; the bridge accepts
#      it and translates). project 'mobissh' is aliased hub-side to 'mobissh-builds'.
#   2. DIRECT (fallback): legacy direct ntfy publish (needs a native tk_ token).
#      Kept only for graceful degradation if the bridge is unset/unreachable.
#
# Config, first found wins:
#   env MOBISSH_NTFY_* / then ~/.mobissh/ntfy.env
#     BRIDGE:  NTFY_BRIDGE (full /notify URL), NTFY_JWT, NTFY_PROJECT
#     DIRECT:  NTFY_URL, NTFY_TOPIC, NTFY_TOKEN
# Secrets (JWT / token) live ONLY in ntfy.env (gitignored home), never the repo.
set -uo pipefail

MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_LOGDIR"
LOGFILE="${MOBISSH_LOGDIR}/notify-ntfy.log"
log() { echo "$(date +%Y%m%dT%H%M%S%z) notify-ntfy: $*" | tee -a "$LOGFILE"; }

CFG="${HOME}/.mobissh/ntfy.env"
if [ -f "$CFG" ]; then . "$CFG"; fi

# Bridge (preferred) config.
BRIDGE="${MOBISSH_NTFY_BRIDGE:-${NTFY_BRIDGE:-}}"
JWT="${MOBISSH_NTFY_JWT:-${NTFY_JWT:-}}"
PROJECT="${MOBISSH_NTFY_PROJECT:-${NTFY_PROJECT:-mobissh}}"

# Direct (fallback) config.
URL="${MOBISSH_NTFY_URL:-${NTFY_URL:-}}"
TOPIC="${MOBISSH_NTFY_TOPIC:-${NTFY_TOPIC:-}}"
TOKEN="${MOBISSH_NTFY_TOKEN:-${NTFY_TOKEN:-}}"

# Lead with the version (TITLE). The open action + Click convey "tap to get the
# APK", so BODY needn't restate it.
TITLE="${1:-MobiSSH build ready}"
CLICK="${2:-}"
BODY="${3:-}"
STAGE="${4:-build-ready}"
# ntfy's Title is a latin-1 HTTP header (the hub bridge maps title→header), so a
# non-ASCII glyph 502s the push. Strip title to printable ASCII — our convention
# is ASCII/monochrome anyway. Body is JSON data (UTF-8 fine), so leave it be.
TITLE="$(printf '%s' "$TITLE" | LC_ALL=C tr -cd '\40-\176')"
# Need a non-empty message; fall back to the title if none was given.
if [ -z "$BODY" ]; then BODY="$TITLE"; fi

# --- 1. BRIDGE (preferred) ---------------------------------------------------
# POST the structured event as JSON with the writer JWT. jq builds the body so a
# title/message with quotes or newlines can't break the JSON.
if [ -n "$BRIDGE" ] && [ -n "$JWT" ] && command -v jq >/dev/null 2>&1; then
  payload="$(jq -nc \
    --arg project "$PROJECT" \
    --arg stage "$STAGE" \
    --arg title "$TITLE" \
    --arg message "$BODY" \
    --arg click "$CLICK" \
    '{project:$project, stage:$stage, title:$title, message:$message, tags:["package"]}
     + (if $click != "" then {click:$click} else {} end)')"
  resp="$(mktemp "${MOBISSH_LOGDIR}/ntfy-bridge.XXXXXX")"
  code="$(curl -sS -m 15 -o "$resp" -w '%{http_code}' \
    -H "Authorization: Bearer ${JWT}" \
    -H "Content-Type: application/json" \
    -d "$payload" "$BRIDGE" 2>>"$LOGFILE" || echo 000)"
  if [ "${code#2}" != "$code" ]; then
    log "sent via bridge (stage=${STAGE} project=${PROJECT} http=${code}) '${TITLE}'"
    rm -f "$resp"
    exit 0
  fi
  log "bridge POST failed (http=${code}) — $(tr -d '\n' <"$resp" 2>/dev/null | cut -c1-200); trying direct"
  rm -f "$resp"
fi

# --- 2. DIRECT (fallback) ----------------------------------------------------
if [ -z "$URL" ] || [ -z "$TOPIC" ]; then
  log "no transport configured (bridge unset/failed and no direct URL+TOPIC) — skipping"
  exit 0
fi
hdrs=(-H "Title: ${TITLE}" -H "Tags: package")
if [ -n "$TOKEN" ]; then hdrs+=(-H "Authorization: Bearer ${TOKEN}"); fi
if [ -n "$CLICK" ]; then hdrs+=(-H "Click: ${CLICK}"); fi
if curl -fsS -m 15 "${hdrs[@]}" -d "${BODY}" "${URL%/}/${TOPIC}" >/dev/null 2>>"$LOGFILE"; then
  log "sent via direct ntfy '${TITLE}' → ${URL%/}/${TOPIC} (click=${CLICK:-none})"
else
  log "direct POST failed (best-effort; build unaffected) → ${URL%/}/${TOPIC}"
fi
exit 0
