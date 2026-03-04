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

## Test Layering Policy
Regression baselines are **frozen reference points**. They capture known-correct behavior
and exist to catch regressions when new features are developed. The policy:

- **Files matching `*-baseline.spec.*` are frozen.** Do not modify test logic, assertions,
  or expected values. The only acceptable changes are: fixing a broken `require`/`import`
  path after a file move, or updating infrastructure calls when a shared fixture API changes
  its signature (and even then, behavior must remain identical).
- **Add new tests alongside baselines, never modify them.** To test new features (horizontal
  swipe, pinch-to-zoom, multi-panel), create new spec files that import the same fixtures.
  Name them descriptively: `gesture-horizontal.spec.js`, `gesture-pinch.spec.js`,
  `gesture-multi-feature.spec.js`.
- **Baselines are additive.** Once a behavior is captured in a baseline, it stays. If the
  application behavior changes intentionally, add a new baseline that captures the new
  behavior and keep the old one (mark it `.skip` with a comment referencing the issue/PR
  that changed behavior, so the history is preserved).
- **Semgrep enforces this.** The `frozen-baseline-test` rule in `.semgrep/playwright-traps.yml`
  flags structural test changes (describe/test/expect) in baseline files. It runs in the
  pre-commit hook and CI.

## Rules
- Build step allowed — TypeScript compilation is acceptable for type safety and static error detection. Compiled output is served from `public/`. No heavy bundlers (webpack, vite) unless justified.
- `node_modules/` is gitignored — install via `npm install` in `server/`
- No secrets in code
- Keep `Cache-Control: no-store` on static responses and SW network-first
- **Never store sensitive data (passwords, private keys, passphrases) in plaintext** — use the encrypted vault (PasswordCredential + AES-GCM) or don't store at all. If the vault is unavailable, block the feature; do not fall back to plaintext storage with a warning.
- **Never prefix script calls with `bash`** — all scripts have shebangs and execute permissions. Call `scripts/foo.sh` not `bash scripts/foo.sh`. The `bash` prefix is redundant and widens the permission surface.
- **Timestamps in filenames/directories use compact ISO-8601 with tz offset** — `date +%Y%m%dT%H%M%S%z` produces `20260303T150827-0500`. Never use bare `%Y%m%d-%H%M%S` (ambiguous timezone).
- **Before submitting a PR, run the full test suite:** `scripts/test-typecheck.sh && scripts/test-lint.sh && scripts/test-unit.sh && scripts/test-headless.sh`. The `webServer` config in `playwright.config.js` auto-starts the server. Fix all failures before submitting.
