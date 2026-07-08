# Feedback Service — bug-report/telemetry extraction (#997)

The server-side bug-report/telemetry surface, extracted from the main
SSH-bridge/static server (`server/index.js`) into a dedicated container
(`mobissh-feedback`), LXC-deploy-ready. This doc is (1) the exact inventory of
the pre-extraction surface, (2) the extracted architecture, (3) cutover
commands, (4) the operator handoff for a PVE LXC deploy.

## 1. Inventory — server-side bug-report surface

### Routes (all previously inline in server/index.js, now in server/feedback-store.js)

| Route | Producer(s) | Payload | Response |
|---|---|---|---|
| `POST /api/bug-report` | native `feedback_overlay.dart` (in-app feedback, #661/#967), PWA `src/modules/bug-report.ts`, install-page form `public/native-feedback.js` | one JSON body: `title`, `comment` (full untruncated note), `logs`, `screenshot` (base64 data URL), `frames[]` (repro burst), `connectLog[]`, `gestureLog[]`, `byteTrace[]` + `scrollTrace[]` + `grid` (#790 replay), `sentSgrTrace[]` (#793), `userAgent`, `url`, `version` | `200 {ok:true,saved:true}`; `400 {"error":"invalid json"}` |
| `POST /api/drop-telemetry` | PWA `src/modules/drop-telemetry.ts` (auto, on reconnect recovery, 5min throttle) | JSON: `kind`, `reason`, `sessionId`, `host`, `connectLog[]`, `gestureLog[]`, meta | `200 {ok:true,stamp}`; `400` |
| `POST /api/gesture-telemetry` | PWA `src/modules/drop-telemetry.ts` (gesture/IME anomaly, #502) | JSON: `reason`, `eventCount`, `log[]`, meta | `200 {ok:true,stamp}`; `400` |
| `POST /api/native-crash` | native `crash_reporter.dart` (Dart + Kotlin uncaught handlers, #501), `public/termux/mobissh-logcat.sh` | one crash JSON (or arbitrary raw text) | `200 {ok:true,path}` / `{ok:true,raw:true,path}`; `413` over 1MB; `500` on write failure |

All producers post to the single Tailscale endpoint
`https://mobissh.tailbe5094.ts.net/api/...` (native default is compile-time:
`MOBISSH_FEEDBACK_ENDPOINT` in `feedback_overlay.dart`; the PUBLIC Play build
overrides it to the Cloudflare Worker in `infra/bug-report-worker/` — that path
is out of scope here). Upload is a single POST per report (no multi-file
sequencing, no client retry loop — a failed send surfaces to the user).

### File naming contract (dev-loop scripts glob these — DO NOT change)

Every file is prefixed with a SERVER-generated stamp
(`new Date().toISOString().replace(/[:.]/g,'-').slice(0,19)`, e.g.
`2026-07-08T14-22-25`). No user-controlled path component ever reaches the
filesystem — that is the filename sanitization.

```
<ts>-bug-report.json                 meta (title, FULL comment, sidecar names, counts, grid)
<ts>-bug-report.png                  screenshot
<ts>-bug-report.log                  logs / full comment sidecar
<ts>-bug-report.frame-NNN.png        repro burst frames (zero-padded, ffmpeg %03d)
<ts>-bug-report.connect-log.json     24h connect/reconnect events
<ts>-bug-report.gesture-log.json     24h gesture events
<ts>-bug-report.byte-trace.json      {grid, byteTrace[], scrollTrace[]} (#790 replay harness)
<ts>-bug-report.sent-sgr-trace.json  {grid, sentSgrTrace[]} (#793)
<stamp>-drop-telemetry.json          meta
<stamp>-drop-telemetry.connect-log.json / .gesture-log.json
<stamp>-gesture-telemetry.json       meta
<stamp>-gesture-telemetry.gesture-log.json
<stamp>-native-crash.json            parsed crash
<stamp>-native-crash.raw             non-JSON crash body (never lost)
```

### Size caps (preserved verbatim in feedback-store.js)

- `/api/native-crash`: request body capped at 1MB → `413` (`MAX_CRASH_BYTES`).
- gesture-telemetry log sidecar: >1MB → keep newest half (`MAX_GESTURE_LOG_BYTES`).
- bug-report frames: max 120 (`MAX_FRAMES`).
- byte/scroll/sent-SGR traces: last 8192 events each (server-side backstop; the
  client bounds the rings).
- Other routes: no request cap (unchanged from pre-extraction behavior).

Secret scrubbing is CLIENT-side (`feedback_bundle.dart scrubSecrets`); the
service stores what it receives. Nothing new is logged beyond the
pre-extraction log lines.

### Storage + consumers (must keep working unchanged — they do)

Files land in `test-results/uploads/`. On the dev host that is ONE directory,
bind-mounted into every container that touches it:

- host path: `/var/lib/docker/volumes/dev_workspace/_data/mobissh/test-results/uploads`
- fd-dev (dev container): `/home/dev/workspace/mobissh/test-results/uploads/`
- mobissh-prod: `/app/test-results/uploads` (docker-compose.prod.yml)
- mobissh-feedback: `/app/test-results/uploads` (docker-compose.feedback.yml)

Consumers (all read the fd-dev path; none change):

- `scripts/watch-bug-reports.sh` — polls `*-bug-report.json` / `*-drop-telemetry.json`
- `scripts/assemble-repro.sh` — `*-bug-report.frame-%03d.png` → mp4/gif
- replay harness / `scripts/paint-replay.sh` — `*-bug-report.byte-trace.json`
- `scripts/pull-feedback.sh` — docker-cp fallback from prod (belt-and-braces; still works)
- SSE events (`bug-report`, `drop-telemetry`, …): emitted by prod's LOCAL path
  only; audit found NO client listens to them, so the proxied path drops them
  (prod still logs `[feedback-proxy] ...` per relayed upload).

## 2. Extracted architecture

```
app ── POST https://mobissh.tailbe5094.ts.net/api/bug-report (unchanged)
        │ (tailscale serve → localhost:8081 inside mobissh-prod)
        ▼
mobissh-prod server/index.js
        │ FEEDBACK_SERVICE_URL set?
        ├─ yes → buffer body → relay verbatim → http://mobissh-feedback:8082 ──▶ feedback-store → uploads bind mount
        │         └─ transport error/timeout → LOG + fall back ↓   (fail-open)
        └─ no/fallback → server/feedback-store.js locally ─────────────────────▶ same uploads bind mount
```

- `server/feedback-store.js` — single source of truth for persistence (naming,
  caps, response bodies). Used by BOTH prod's local/fallback path and the
  service, so semantics cannot drift.
- `server-feedback/index.js` — the dedicated service. Plain `node:http`, zero
  dependencies. Routes above + `GET /healthz`. Retention knob
  `FEEDBACK_RETENTION_DAYS` (default 0 = keep everything; sweep on boot + daily).
- `docker/feedback/Dockerfile` — build context is the repo root (shares
  feedback-store.js). `docker-compose.feedback.yml` joins the external
  `mobissh` network (Docker DNS; no port mapping — docker-proxy is absent).
- Proxy in `server/index.js` (`handleFeedbackUpload`): buffers the raw body
  (the old handlers buffered too), forwards it unmodified with a 10s timeout
  (`FEEDBACK_PROXY_TIMEOUT_MS`), relays the service's response verbatim
  (including 413/400 — the caps live in the shared store either way). Only
  TRANSPORT errors fall back to local handling, so a report is never lost when
  the telemetry container is down. Duplicate risk on a timeout-after-write is
  accepted (duplicate > lost).
- Security: nothing is exposed beyond the tailnet. The service listens only on
  the internal `mobissh` bridge network; the app still talks to the single
  Tailscale endpoint. No new auth surface; no secrets in code or logs.

### Tests

- `server-feedback/test.js` (`npm test` in `server-feedback/`) — round-trip of
  all four routes against a temp dir, exact filename contract, 1MB crash cap,
  raw-crash preservation, retention sweep, healthz.
- `server/test.js` (`npm test` in `server/`) — proxy pass-through (stub service
  receives the raw body, response relayed verbatim), fail-open fallback
  (unreachable service → local file written), pre-cutover local default.

## 3. Cutover (explicit, owner-run; nothing flips silently)

Pre-cutover state after merging this PR: NOTHING changes on the live
mobissh-prod container (it runs the old image until rebuilt).

```
scripts/feedback-ctl.sh start        # build + start mobissh-feedback on the mobissh network
scripts/feedback-ctl.sh status       # healthz + code-currency check
scripts/container-ctl.sh restart     # rebuild prod: picks up the proxy code + FEEDBACK_SERVICE_URL default
```

Verification: file a test report from the app (or `curl -X POST .../api/bug-report`
over the tailnet), then check `docker logs mobissh-prod` for
`[feedback-proxy] /api/bug-report -> http://mobissh-feedback:8082 (200)` and the
file in `/home/dev/workspace/mobissh/test-results/uploads/`.

Rollback / disable proxying (keep the new prod image, handle locally):
recreate prod with the env EXPLICITLY empty — `FEEDBACK_SERVICE_URL=` (the
compose default uses `${FEEDBACK_SERVICE_URL-…}`, no colon, so an empty value
disables). Fallback also engages automatically whenever the service is down —
`scripts/feedback-ctl.sh stop` alone never loses reports.

Retention: default keeps everything. To enable pruning, recreate the service
with e.g. `FEEDBACK_RETENTION_DAYS=90`.

## 4. Operator handoff — PVE LXC deploy (raserver-home-it)

Modeled on the emulator-container arc (docker-compose file in repo root +
docker/ build dir; fd-dev drives docker against the shared daemon; the operator
does host-side provisioning). Two supported shapes:

**A. Same Docker daemon as today (no host work needed).** The service is just
another sibling container on the `mobissh` bridge network. Everything in
section 3 works as-is. Nothing to provision.

**B. Dedicated LXC on PVE (this issue's ask).** Provision like the emulator
LXC, but far lighter — this is a tiny stateless-ish Node HTTP service plus a
data directory:

- Unprivileged LXC, 1 vCPU / 512MB is plenty. No GPU, no KVM, no TUN needed
  (the service itself does NOT run Tailscale; mobissh-prod remains the single
  Tailscale endpoint and proxies over the internal network).
- Runtime: either `docker compose -f docker-compose.feedback.yml up -d` inside
  the LXC (needs nesting for Docker) or bare `node server-feedback/index.js`
  with Node >= 18 (zero npm deps — copy `server-feedback/` +
  `server/feedback-store.js`, keep the relative layout).
- Storage: bind-mount the uploads directory into the LXC and export it to the
  dev environment. The HARD requirement is that fd-dev keeps seeing the files
  at `/home/dev/workspace/mobissh/test-results/uploads/` — today that is the
  host path `/var/lib/docker/volumes/dev_workspace/_data/mobissh/test-results/uploads`.
  If the LXC lives on the same PVE host, an LXC mountpoint (`mpN:`) to that
  path preserves dev-loop parity with zero changes. If it lives elsewhere, an
  NFS/SSHFS export back to that path is required before cutover.
- Network: mobissh-prod must reach the service at port 8082. Same host: attach
  the LXC to the bridge and set `FEEDBACK_SERVICE_URL=http://<lxc-ip-or-name>:8082`
  on mobissh-prod (compose env). The service needs NO inbound exposure beyond
  that one consumer — do not publish it on the tailnet or LAN-wide.
- Env: `PORT=8082`, `UPLOADS_DIR=<mounted dir>`, `FEEDBACK_RETENTION_DAYS=0`.
- Health: `GET http://<service>:8082/healthz` → `{ok:true,service:"mobissh-feedback",...}`.
  `scripts/feedback-ctl.sh status` covers the Docker shape; for a bare-node LXC
  use the healthz URL directly.
- Fail-open means the LXC can be provisioned/rebooted at leisure: while it is
  down, mobissh-prod handles uploads locally into the same directory.
