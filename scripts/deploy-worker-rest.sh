#!/usr/bin/env bash
# Deploy the bug-report Worker via the Cloudflare REST API (account-token
# friendly — avoids wrangler's user-scoped /memberships call). Uploads the ES
# module + bindings (R2 bucket + FEEDBACK_KEY secret inline), enables the
# workers.dev subdomain, prints the URL, and smoke-tests it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKER_DIR="${REPO_ROOT}/infra/bug-report-worker"
MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"
LOGFILE="${MOBISSH_LOGDIR}/deploy-worker-rest.log"
exec > >(tee -a "$LOGFILE") 2>&1

# shellcheck disable=SC1090
. "${HOME}/.mobissh/cloudflare.env"
: "${CLOUDFLARE_API_TOKEN:?}"; : "${CLOUDFLARE_ACCOUNT_ID:?}"

# Keys in ~/.mobissh/feedback.env (never the repo):
#   FEEDBACK_KEY — shared app<->worker write key (baked into the app).
#   VIEW_KEY     — viewer Basic-auth password (browser only; NOT in the app).
# Reuse if present, else generate + persist both.
FEEDBACK_ENV="${HOME}/.mobissh/feedback.env"
if [ -f "$FEEDBACK_ENV" ]; then
  # shellcheck disable=SC1090
  . "$FEEDBACK_ENV"
fi
[ -n "${FEEDBACK_KEY:-}" ] || FEEDBACK_KEY="$(openssl rand -hex 32)"
[ -n "${VIEW_KEY:-}" ] || VIEW_KEY="$(openssl rand -hex 24)"
{ printf 'FEEDBACK_KEY=%s\n' "$FEEDBACK_KEY"; printf 'VIEW_KEY=%s\n' "$VIEW_KEY"; } > "$FEEDBACK_ENV"
chmod 600 "$FEEDBACK_ENV"
echo "> keys ready in $FEEDBACK_ENV (FEEDBACK_KEY + VIEW_KEY)"

SCRIPT_NAME="mobissh-bug-report"
API="https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}"
AUTH="Authorization: Bearer ${CLOUDFLARE_API_TOKEN}"

# 1. Upload the worker (module + metadata with r2 + inline secret bindings).
META="${MOBISSH_TMPDIR}/worker-metadata.json"
printf '{"main_module":"worker.js","compatibility_date":"2026-01-01","bindings":[{"type":"r2_bucket","name":"REPORTS","bucket_name":"mobissh-bug-reports"},{"type":"secret_text","name":"FEEDBACK_KEY","text":"%s"},{"type":"secret_text","name":"VIEW_KEY","text":"%s"}]}' "$FEEDBACK_KEY" "$VIEW_KEY" > "$META"
echo "> uploading worker script"
curl -sS -m 60 -X PUT "${API}/workers/scripts/${SCRIPT_NAME}" \
  -H "$AUTH" \
  -F "metadata=@${META};type=application/json" \
  -F "worker.js=@${WORKER_DIR}/worker.js;type=application/javascript+module"
echo
rm -f "$META"   # contained the secret

# 2. Resolve the account workers.dev subdomain.
echo "> resolving workers.dev subdomain"
SUB_JSON="$(curl -sS -m 30 "${API}/workers/subdomain" -H "$AUTH")"
echo "$SUB_JSON"
SUBDOMAIN="$(printf '%s' "$SUB_JSON" | grep -oP '"subdomain"\s*:\s*"\K[^"]+' || true)"
if [ -z "$SUBDOMAIN" ]; then
  echo "! no workers.dev subdomain registered on this account."
  echo "  Register one (unique name) then re-run:"
  echo "  scripts/cf-api.sh PUT /workers/subdomain --data '{\"subdomain\":\"YOURNAME\"}'"
  exit 3
fi

# 3. Enable the workers.dev route for this script.
echo "> enabling workers.dev route for ${SCRIPT_NAME}"
curl -sS -m 30 -X POST "${API}/workers/scripts/${SCRIPT_NAME}/subdomain" \
  -H "$AUTH" -H "Content-Type: application/json" \
  --data '{"enabled":true,"previews_enabled":false}'
echo

URL="https://${SCRIPT_NAME}.${SUBDOMAIN}.workers.dev"
echo "+ DEPLOYED"
echo "  ingest (app POST): ${URL}"
echo "  viewer (browser):  ${URL}/           (Basic auth — any user, password = VIEW_KEY)"
echo "  privacy policy:    ${URL}/privacy    (public)"
echo "$URL" > "${MOBISSH_TMPDIR}/worker-url.txt"
