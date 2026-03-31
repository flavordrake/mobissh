# MobiSSH -- Claude Code Context

> **Active TRACE**: `.traces/trace-post-v1-polish-131724/` — post-v1.0 bug fixes, reconnect polish, supply chain

## Command Hygiene (read this first)
- **One script per Bash call.** No `&&` chains, no `;` sequences, no compound commands.
- **No shell redirects.** Scripts handle their own output. No `> /tmp/foo`, no `2>/dev/null`.
- **No heredocs in Bash.** Use the Write tool to create files, then pass `--body-file`.
- **No `model` parameter on Agent calls.** Agents inherit parent permissions; setting model can break this.
- **Use `scripts/gh-ops.sh`** for ALL GitHub operations. Never raw `gh` commands.

Every violation creates approval noise on mobile. Wrapper scripts exist for a reason.

## What This Is
MobiSSH is a mobile-first SSH PWA (Progressive Web App). A Node.js WebSocket bridge
proxies SSH connections; xterm.js renders the terminal in-browser. Designed to be
installed on Android/iOS home screens and used over Tailscale (WireGuard mesh).

Graduated from `poc/android-ssh` in `flavordrake/threadeval` @ tag `android-ssh-v0.1`.

## Architecture
- **`server/index.js`** -- single Node.js process: HTTP static file server + WebSocket SSH bridge on port 8081
- **`public/`** -- PWA frontend (ES modules, TypeScript eligible)
  - `app.js` -- main application entry point (imports from `modules/`)
  - `modules/constants.js` -- pure constants and configuration
  - `app.css` -- mobile-first styles
  - `index.html` -- shell (`<script type="module">`)
  - `sw.js` -- service worker (network-first, cache for offline fallback)
  - `manifest.json`, `icon-*.svg` -- PWA metadata

## Key Decisions
- Single port 8081 for both static files and WS bridge
- `Cache-Control: no-store` on all static responses; SW is network-first (no stale cache)
- WS URL: same-origin detection via `getDefaultWsUrl()` -- works in Codespaces (wss://) and local (ws://)
- Credential vault: AES-GCM, 256-bit key stored in `PasswordCredential` (Chrome/Android biometric)
  - iOS: `PasswordCredential` not supported -- needs WebAuthn path (#2)
- Profile upsert: match on host+port+username, update in place (no duplicates)
- IME input: hidden `#imeInput` textarea captures swipe/voice/keyboard; `ctrlActive` sticky modifier

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
- **Local server** (`scripts/server-ctl.sh`): headless Playwright tests only, NOT for user testing
- **Test SSH** (`docker-compose.test.yml`): Alpine sshd for integration tests
  - Credentials: `testuser`/`testpass`, ed25519 key in `docker/test-sshd/`
  - `tests/emulator/sshd-fixture.js` handles lifecycle, network join, and key permissions
- Personal use over Tailscale (WireGuard mesh) -- bridge auth and SSRF handled at network layer

## Backlog -- GitHub Issues
All backlog items are filed as issues in this repo. Use `gh issue list` for current state.
Use `/delegate` to scan, classify, and dispatch bot-ready issues.
Use `/integrate` to review, gate, and merge bot PRs.

## iOS Compatibility Summary (researched Feb 2026)
- WSS, SubtleCrypto/AES-GCM, xterm.js canvas, visualViewport: all work iOS 13+
- `PasswordCredential`: NOT supported on iOS Safari -> WebAuthn needed (#2)
- Practical minimum for full feature parity: iOS 16
- Hidden textarea needs `autocorrect="off"` etc. or iOS corrupts SSH commands
- `visualViewport.height` is the correct API (not `window.innerHeight`) for keyboard detection

## Rules
Detailed rules live in `.claude/rules/` (modular, some path-scoped):
- `security.md` -- credential vault, no plaintext, no secrets
- `testing.md` -- frozen baseline policy, test gates, emulator rules (scoped to `tests/`)
- `scripts.md` -- script conventions, timestamps (scoped to `scripts/`)
- `code-style.md` -- CSS over inline, no separators, build policy
- `server.md` -- Docker container deployment, server-ctl.sh (headless tests only)
- `typescript.md` -- strict mode, compilation, imports (scoped to `src/`)
- `agents.md` -- delegation, integration, worktree isolation
- `workflow.md` -- issue workflow, PR checklist, inferred constraints

## TRACE Protocol
Development arcs are captured in `.traces/` (gitignored, local). Use `scripts/trace-init.sh <slug>`
to start a new TRACE. See `.claude/skills/agent-trace/SKILL.md` for full protocol.
Active TRACE should be referenced at top of this file for session continuity.
