#!/usr/bin/env bash
# Thin Cloudflare account-API wrapper. Sources the token + account id from
# ~/.mobissh/cloudflare.env (never the repo) and curls an account-scoped path.
# Usage: scripts/cf-api.sh <METHOD> <account-path> [extra curl args...]
#   scripts/cf-api.sh GET  /workers/scripts
#   scripts/cf-api.sh POST /r2/buckets --data '{"name":"x"}'
set -euo pipefail

CF_ENV="${HOME}/.mobissh/cloudflare.env"
# shellcheck disable=SC1090
. "$CF_ENV"

METHOD="${1:?method}"
API_PATH="${2:?account path}"
shift 2

curl -sS -m 30 -X "$METHOD" \
  "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}${API_PATH}" \
  -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
  -H "Content-Type: application/json" \
  "$@"
echo
