#!/usr/bin/env bash
# Smoke-test the deployed bug-report Worker: an authed POST should store (200
# {ok}), an unauthed POST should be rejected (403). Reads the key + URL from the
# home env / tmp (never the repo).
set -euo pipefail

MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
# shellcheck disable=SC1090
. "${HOME}/.mobissh/feedback.env"
: "${FEEDBACK_KEY:?}"
URL="${WORKER_URL:-$(cat "${MOBISSH_TMPDIR}/worker-url.txt")}"
echo "> worker: $URL"

echo "> authed POST (expect 200 {ok}):"
curl -sS -m 30 -w '\n[http %{http_code}]\n' -X POST "$URL" \
  -H "X-MobiSSH-Key: ${FEEDBACK_KEY}" \
  -H "Content-Type: application/json" \
  --data '{"title":"deploy smoke","comment":"deploy smoke test","version":"[deploy]","source":"deploy-smoke"}'

echo "> unauthed POST (expect 403):"
curl -sS -m 30 -w '\n[http %{http_code}]\n' -X POST "$URL" \
  -H "Content-Type: application/json" \
  --data '{"comment":"should be rejected"}'
