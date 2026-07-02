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

## One-time deploy
Prereqs: a Cloudflare account, `npm i -g wrangler`, `wrangler login`.

```
# 1. create the bucket
wrangler r2 bucket create mobissh-bug-reports

# 2. set the shared key (any long random string) — the app must send the same
wrangler secret put FEEDBACK_KEY          # paste the value when prompted

# 3. (optional) auth token if you set NTFY_URL to an authed topic
# wrangler secret put NTFY_TOKEN

# 4. deploy (from this dir)
wrangler deploy
```

`wrangler deploy` prints the URL, e.g. `https://mobissh-bug-report.<you>.workers.dev`.

## Point the app at it
Build the public AAB with the endpoint + key baked in:

```
scripts/flutter-cmd.sh --in native build appbundle --release \
  --dart-define=MOBISSH_FEEDBACK_ENDPOINT=https://mobissh-bug-report.<you>.workers.dev \
  --dart-define=MOBISSH_FEEDBACK_KEY=<the FEEDBACK_KEY value>
```

(build-release-aab.sh can pass these through — set `FEEDBACK_ENDPOINT` /
`FEEDBACK_KEY` env vars; a follow-up wires them in.) The personal/tailnet build
omits both defines and keeps posting to the tailnet endpoint with no key header.

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
