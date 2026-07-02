# MobiSSH public bug-report endpoint (Cloudflare Worker)

The public Play build can't reach the tailnet `/api/bug-report`, so it POSTs the
report (after the in-app **Review & Send** consent gate, #967) to this Worker,
which stores it in **your** R2 bucket. You are the sole recipient — no
third-party analytics/trackers, and you own retention/deletion (matches
`docs/PRIVACY.md`).

## Why a self-owned Worker (not Crashlytics/Sentry)
A crash/feedback SaaS auto-collects device identifiers and adds a third-party
data processor, which expands the Play data-safety declaration and dilutes the
"we never see your data" story. A Worker + R2 keeps you as the only recipient,
keeps the existing JSON payload, and stays on Cloudflare's free tier for this
volume (Workers 100k req/day, R2 10 GB).

## One-time deploy (REST — account-token friendly)

We deploy via the Cloudflare REST API, NOT `wrangler`: this project uses an
**account-owned** API token (recommended — not tied to a person), and wrangler
makes a user-scoped `/memberships` call that account tokens can't answer
(`code 9106`). The REST path takes the explicit account scope and works cleanly.

Prereqs — credentials in the home dir (never the repo):
```
# account-owned API token with: Workers Scripts:Edit + Workers R2 Storage:Edit
#   ~/.mobissh/cloudflare.env  →  CLOUDFLARE_API_TOKEN=...  and  CLOUDFLARE_ACCOUNT_ID=...
```
Then:
```
scripts/cf-api.sh POST /r2/buckets --data '{"name":"mobissh-bug-reports"}'   # create bucket
scripts/deploy-worker-rest.sh                                                 # upload + bindings + subdomain
scripts/verify-worker.sh                                                      # authed 200 / unauthed 403 smoke test
```
`deploy-worker-rest.sh` generates + persists the shared `FEEDBACK_KEY` to
`~/.mobissh/feedback.env`, uploads the module with the R2 + secret bindings
inline, enables the workers.dev route, and prints the URL — e.g.
`https://mobissh-bug-report.flavordrake.workers.dev`. (If the account has no
workers.dev subdomain yet: `scripts/cf-api.sh PUT /workers/subdomain --data '{"subdomain":"NAME"}'`.)

## Point the app at it
Build the public AAB with the endpoint + key baked in:

```
scripts/flutter-cmd.sh --in native build appbundle --release \
  --dart-define=MOBISSH_FEEDBACK_ENDPOINT=https://mobissh-bug-report.<you>.workers.dev \
  --dart-define=MOBISSH_FEEDBACK_KEY=<the FEEDBACK_KEY value>
```

Or, simpler: `FEEDBACK_ENDPOINT=… FEEDBACK_KEY=… scripts/build-release-aab.sh`
— the script passes both through as `--dart-define`s. The personal/tailnet build
omits both and keeps posting to the tailnet endpoint with no key header.

## Reading reports
```
wrangler r2 object get mobissh-bug-reports --prefix reports/   # list/browse
```
Each object is the report JSON (comment, version, and whatever the user chose to
include: screenshot/frames as base64 data URLs, traces). Custom metadata carries
`version`, `hasScreenshot`, `frameCount` for quick triage.

## Contract
- `POST` JSON, header `X-MobiSSH-Key: <FEEDBACK_KEY>`.
- 25 MB body cap. Returns `200 {ok,id}`; `403` bad/missing key; `413` too large;
  `400` invalid JSON.
- Stores to `reports/<date>/<ts>-<uuid>.json`; optional ntfy ping on receipt.
