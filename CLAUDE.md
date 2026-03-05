# MobiSSH — Claude Code Context

## What This Is
MobiSSH is a mobile-first SSH PWA (Progressive Web App). A Node.js WebSocket bridge
proxies SSH connections; xterm.js renders the terminal in-browser. Designed to be
installed on Android/iOS home screens and used over Tailscale (WireGuard mesh).

Graduated from `poc/android-ssh` in `flavordrake/threadeval` @ tag `android-ssh-v0.1`.

## Architecture
- **`server/index.js`** — single Node.js process: HTTP static file server + WebSocket SSH bridge on port 8080
- **`public/`** — PWA frontend (ES modules, TypeScript eligible)
  - `app.js` — main application entry point (imports from `modules/`)
  - `modules/constants.js` — pure constants and configuration
  - `app.css` — mobile-first styles
  - `index.html` — shell (`<script type="module">`)
  - `sw.js` — service worker (network-first, cache for offline fallback)
  - `manifest.json`, `icon-*.svg` — PWA metadata

## Key Decisions
- Single port 8081 for both static files and WS bridge; nginx proxies HTTPS on Tailscale endpoint
- `Cache-Control: no-store` on all static responses; SW is network-first (no stale cache)
- WS URL: same-origin detection via `getDefaultWsUrl()` — works in Codespaces (wss://) and local (ws://)
- Credential vault: AES-GCM, 256-bit key stored in `PasswordCredential` (Chrome/Android biometric)
  - iOS: `PasswordCredential` not supported — needs WebAuthn path (issue #14)
- Profile upsert: match on host+port+username, update in place (no duplicates)
- IME input: hidden `#imeInput` textarea captures swipe/voice/keyboard; `ctrlActive` sticky modifier

## Deployment Context
- Personal use over Tailscale (WireGuard mesh) — bridge auth and SSRF handled at network layer
- Start server: `scripts/server-ctl.sh start` (never raw `node server/index.js`)
- Production container: #158 (docker-compose.prod.yml on port 8082, nginx routes to it)

## Backlog — GitHub Issues
All backlog items are filed as issues in this repo. Use `gh issue list` for current state.
Key active delegations (bot label): #21, #70, #158, #171, #172, #173, #176.
Decomposed parents: #129 (→ #176, #177), #138 (→ #173, #174, #175).

## iOS Compatibility Summary (researched Feb 2026)
- WSS, SubtleCrypto/AES-GCM, xterm.js canvas, visualViewport: all work iOS 13+
- `PasswordCredential`: NOT supported on iOS Safari → WebAuthn needed (issue #14)
- Practical minimum for full feature parity: iOS 16
- Hidden textarea needs `autocorrect="off"` etc. or iOS corrupts SSH commands (issue #10)
- `visualViewport.height` is the correct API (not `window.innerHeight`) for keyboard detection

## Rules
Detailed rules live in `.claude/rules/` (modular, some path-scoped):
- `security.md` — credential vault, no plaintext, no secrets
- `testing.md` — frozen baseline policy, test gates, emulator rules (scoped to `tests/`)
- `scripts.md` — script conventions, timestamps (scoped to `scripts/`)
- `code-style.md` — CSS over inline, no separators, build policy
- `server.md` — server-ctl.sh, cache-control, deployment
- `typescript.md` — strict mode, compilation, imports (scoped to `src/`)
- `agents.md` — delegation, integration, worktree isolation
- `workflow.md` — issue workflow, PR checklist, inferred constraints
