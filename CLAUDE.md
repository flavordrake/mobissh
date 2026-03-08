# MobiSSH -- Claude Code Context

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

## Deployment
- **Production**: Docker container (`docker-compose.prod.yml`) with built-in Tailscale (`tailscale serve`)
  - Rebuild: `scripts/container-ctl.sh restart`
  - Container copies `public/` and `server/` at build time -- must rebuild after code changes
- **Local server** (`scripts/server-ctl.sh`): headless Playwright tests only, NOT for user testing
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
