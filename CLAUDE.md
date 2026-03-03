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
- Single port 8080 for both static files and WS bridge (simplifies Codespaces port forwarding)
- `Cache-Control: no-store` on all static responses; SW is network-first (no stale cache)
- WS URL: same-origin detection via `getDefaultWsUrl()` — works in Codespaces (wss://) and local (ws://)
- Credential vault: AES-GCM, 256-bit key stored in `PasswordCredential` (Chrome/Android biometric)
  - iOS: `PasswordCredential` not supported — needs WebAuthn path (issue #14)
- Profile upsert: match on host+port+username, update in place (no duplicates)
- IME input: hidden `#imeInput` textarea captures swipe/voice/keyboard; `ctrlActive` sticky modifier

## Deployment Context
- Personal use over Tailscale (WireGuard mesh) — bridge auth and SSRF handled at network layer
- Codespaces devcontainer: port 8080, `gh` CLI via feature, Claude Code extension pre-installed
- Start server: `cd server && npm start`

## Backlog — GitHub Issues
All backlog items are filed as issues in this repo. Key priorities:

**UX (issues #1–3)**
- #1 Auto-hide key bar (swipe-up to reveal)
- #2 Char-entry mode vs IME mode toggle (latency vs autocorrect)
- #3 Two-line key bar (status row + keys row)

**Feature (issue #4)**
- #4 Multi-session support — session map, per-session xterm.js, top toolbar tab switching

**Security (issues #5–9)**
- #5 SSH host key verification — store fingerprint on first connect, warn on mismatch (highest real risk)
- #6 SSRF prevention (RFC-1918 blocklist)
- #7 SRI hashes for xterm.js CDN tags
- #8 Content-Security-Policy header
- #9 Hard-reject ws:// in settings

**iOS (issues #10–14)**
- #10 Quick fix: `autocorrect="off" autocapitalize="off" autocomplete="off"` on `#imeInput`
- #11 Safe area insets (notch/Dynamic Island)
- #12 `overscroll-behavior: none` on terminal
- #13 Apple PWA meta tags for standalone install
- #14 WebAuthn vault path (iOS 16+ replacement for PasswordCredential)

**Touch / tmux (issues #15–18)**
- #15 xterm.js mouse protocol reporting (DECSET 1000/1002/1006)
- #16 Swipe-left/right → tmux prev/next window
- #17 Pinch-to-zoom → font size
- #18 Long-press → right-click / tmux copy mode

**Image passthrough (issues #19–21)**
- #19 Detect sixel / iTerm2 / Kitty inline image sequences
- #20 Render as overlay with copy-as-base64 (for Claude CLI on mobile)
- #21 Evaluate xterm.js ImageAddon

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
