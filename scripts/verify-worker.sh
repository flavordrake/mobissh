#!/usr/bin/env bash
# Smoke-test the deployed bug-report Worker across all routes. Reads keys + URL
# from the home env / tmp (never the repo).
#   ingest authed  → 200 {ok}      ingest unauthed → 403
#   GET /privacy   → 200 (public)  GET / no-auth    → 401   GET / authed → 200
set -euo pipefail

MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
# shellcheck disable=SC1090
. "${HOME}/.mobissh/feedback.env"
: "${FEEDBACK_KEY:?}"; : "${VIEW_KEY:?}"
URL="${WORKER_URL:-$(cat "${MOBISSH_TMPDIR}/worker-url.txt")}"
echo "> worker: $URL"

echo "> ingest authed (expect 200 {ok}):"
curl -sS -m 30 -w '\n[http %{http_code}]\n' -X POST "$URL" \
  -H "X-MobiSSH-Key: ${FEEDBACK_KEY}" -H "Content-Type: application/json" \
  --data '{"title":"deploy smoke","comment":"deploy smoke test","version":"[deploy]","source":"deploy-smoke"}'

echo "> ingest unauthed (expect 403):"
curl -sS -m 30 -w '\n[http %{http_code}]\n' -X POST "$URL" \
  -H "Content-Type: application/json" --data '{"comment":"nope"}'

echo "> GET /privacy (expect 200, public):"
curl -sS -m 30 -o /dev/null -w '[http %{http_code}]\n' "$URL/privacy"

echo "> GET / no auth (expect 401):"
curl -sS -m 30 -o /dev/null -w '[http %{http_code}]\n' "$URL/"

echo "> GET / with viewer auth (expect 200):"
curl -sS -m 30 -o /dev/null -w '[http %{http_code}]\n' -u "admin:${VIEW_KEY}" "$URL/"
