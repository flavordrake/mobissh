# MobiSSH -- Claude Code Context

> **Active TRACE**: `.traces/trace-link-browser-routing-1195-175316/` — per-profile browser for extracted links #1195 (spec `docs/link-browser-routing.md`; slice 1 #1196 platform seam IN PROGRESS, device; slice 2 #1197 routing+settings waits on it). Prior arcs: `.traces/trace-jump-host-1182-183208/` (#1182 COMPLETE, shipped +188 — device validation owed), `.traces/trace-link-highlight-options-222819/` — link highlight options #1153 (spec `docs/link-highlight-options.md`; slice 1 #1154 intensity+sheet MERGED 2026-09-16; slice 2 #1155 gutter side + column mode IN PROGRESS, device). Side arcs: coverage tooling #1152 merged (Phase 2 assessment → backfill issues pending); deep-link emulator gap #1151 merged. Prior arcs: `.traces/trace-deep-link-intents-1117-200922/` (#1117, shipped +184; owner device validation owed; claude verb R24 deferred), `.traces/trace-fleet-emulator-gate-restore-003808/`. Durable learnings in memory.

## Command Hygiene (read this first)
- **One script per Bash call.** No `&&` chains, no `;` sequences, no compound commands.
- **No shell redirects.** Scripts handle their own output. No `> /tmp/foo`, no `2>/dev/null`.
- **No heredocs in Bash.** Use the Write tool to create files, then pass `--body-file`.
- **No `model` parameter on Agent calls.** Agents inherit parent permissions; setting model can break this.
- **Use `scripts/gh-ops.sh`** for ALL GitHub operations. Never raw `gh` commands.

Every violation creates approval noise on mobile. Wrapper scripts exist for a reason.

## What This Is
MobiSSH is a mobile-first SSH client: a **Flutter native app** (`native/`) that speaks
SSH directly via dartssh2, used over Tailscale (WireGuard mesh).

The PWA web app it grew out of was **retired 2026-09-21 (#1205)**. Its UX is still the
spec the native app duplicates — read `src/`-era references in docs as history, and look
in git for the code.

Graduated from `poc/android-ssh` in `flavordrake/threadeval` @ tag `android-ssh-v0.1`.

## Architecture
- **`native/`** -- the Flutter app: the product. `native/third_party/flterm` is the
  vendored terminal fork; rendering goes through libghostty via FFI.
- **`server/index.js`** -- single Node.js process on port 8081: static files, the native
  install page + artifacts, the bug-report/telemetry relay, and the Claude Code approval
  bridge (`/api/approval*` + the `/events` SSE channel).
- **`server-feedback/`** -- the feedback-service container `server/index.js` relays to.
- **`public/`** -- served verbatim; no build step.
  - `native.html` -- generated install page (gitignored)
  - `native-time.js`, `native-feedback.js` -- the only two scripts it loads
  - `index.html` -- a redirect stub so `/` forwards to the install page

## Key Decisions
- Single port 8081; `Cache-Control: no-store` on all static responses
- No web build step — the PWA's TypeScript sources were retired in #1205
- Profile upsert: match on host+port+username, update in place (no duplicates)
- `/clear` is kept deliberately: it is the only way to unregister the retired PWA's
  service worker from a device that already installed it

## Container Environment
Claude Code runs inside a Docker container (`fd-dev`). All other containers are **siblings**,
not children -- they share the Docker daemon via socket mount, not nested Docker.

### Shared network: `mobissh`
All MobiSSH containers join a named Docker network `mobissh` (bridge driver).
Containers reach each other via Docker DNS names, NOT `localhost` port mapping.
`docker-proxy` is not available in this environment -- port forwarding does not work.

| Container | DNS name | Purpose |
|-----------|----------|---------|
| `fd-dev` | `fd-dev` | Dev environment (this container) |
| `mobissh-prod` | `mobissh-prod` / `mobissh` | Production server (Tailscale + Node.js) |
| `mobissh-test-sshd-1` | `test-sshd` | Test SSH target (Alpine + OpenSSH) |

- Network is created idempotently by scripts (`docker network create mobissh`)
- Both `docker-compose.prod.yml` and `docker-compose.test.yml` use `external: true`
- Scripts auto-join this container to the network (`docker network connect mobissh $(hostname)`)
- SSH to test-sshd: `test-sshd:22` (not `localhost:2222`)
- MobiSSH server URL from tests: `http://mobissh-prod:8081` or `http://localhost:8081` (via local server-ctl)

### Deployment
- **Production**: Docker container (`docker-compose.prod.yml`) with built-in Tailscale (`tailscale serve`)
  - Rebuild: `scripts/container-ctl.sh restart`
  - Container copies `public/` and `server/` at build time -- must rebuild after code changes
- **Local server** (`scripts/server-ctl.sh`): a local copy of the static/telemetry server, NOT for user testing
- **Test SSH** (`docker-compose.test.yml`): Alpine sshd for integration tests
  - Credentials: `testuser`/`testpass`, ed25519 key in `docker/test-sshd/`
  - `scripts/lib/testsshd-fixture.sh` handles lifecycle, network join, and key permissions
- Personal use over Tailscale (WireGuard mesh) -- bridge auth and SSRF handled at network layer

### Native app builds
- **Versioning**: `x.y.z[-STAGE]+B` per `docs/VERSIONING.md` — B is a global never-resetting build ordinal (== Android versionCode); stages flow `-dev` → `-rc.N` → final.
- **Android APK**: `scripts/ship-native.sh` (build + publish to `native.html`), local on fd-dev.
- **macOS app**: built on matts-macbook-air (only Xcode host), published to `native.html` from fd-dev. Kick off with `scripts/dispatch-mac-build.sh`; full pipeline in `native/MAC-BUILD.md`. iOS device builds are out of scope (signing-gated).

## Backlog -- GitHub Issues
All backlog items are filed as issues in this repo. Use `gh issue list` for current state.
Use `/delegate` to scan, classify, and dispatch bot-ready issues.
Use `/integrate` to review, gate, and merge bot PRs.

## Rules
Detailed rules live in `.claude/rules/` (modular, some path-scoped):
- `security.md` -- credential vault, no plaintext, no secrets
- `testing.md` -- test gates, the integration baseline contract, emulator rules
- `scripts.md` -- script conventions, timestamps (scoped to `scripts/`)
- `code-style.md` -- CSS over inline, no separators, build policy
- `server.md` -- Docker container deployment, server-ctl.sh, Docker networking
- `agents.md` -- delegation, integration, worktree isolation
- `workflow.md` -- issue workflow, PR checklist, inferred constraints

## TRACE Protocol
Development arcs are captured in `.traces/` (gitignored, local). Use `scripts/trace-init.sh <slug>`
to start a new TRACE. See `.claude/skills/agent-trace/SKILL.md` for full protocol.
Active TRACE should be referenced at top of this file for session continuity.
