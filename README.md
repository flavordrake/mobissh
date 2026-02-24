# MobiSSH

A mobile-first SSH PWA (Progressive Web App) with a WebSocket bridge. Install to your Android or iOS home screen and use it like a native app over Tailscale or any network.

> **Not a remote agent controller.** MobiSSH is standard SSH, made mobile-friendly. The bridge is a thin WebSocket proxy — it forwards bytes between your browser and the SSH server, nothing more. No command interception, no custom control plane, no proprietary protocol.

---

## Why this exists

Most mobile SSH clients fail the same way: they treat the terminal as a text viewer with a keyboard bolted on. That works for quick `ls` or reading a log file. It breaks down the moment you open `vim`, `htop`, `tmux`, or agentic coding tools like OpenCode, Gemini CLI, Codex, and Claude Code.

### The specific problems with existing mobile SSH apps

**Highly interactive TUI apps depend on exact key sequences.** `vim` enters insert mode on `i`, exits on `Esc`, saves with `:wq`. `tmux` multiplexes windows with `Ctrl-b c`. `htop` sorts columns with arrow keys. Every one of these depends on the app receiving a precise byte sequence — not an autocorrected, swipe-predicted, autocapitalized string.

Android and iOS soft keyboards were designed for messaging apps. When you type in a messaging app, autocorrect is your friend. When you type `ggVGy` in a vim window, autocorrect is catastrophic.

**Existing clients solve the key-sequence problem but break IME input.** Apps like JuiceSSH, ConnectBot or Termius disable autocorrect globally, which means you lose swipe-to-type, voice dictation, and predictive text — the features that make typing long text on a phone bearable. Writing a commit message or a comment in an SSH session becomes hunt-and-peck.

**A configurable special-key bar.** Arrow keys, Escape, Tab, Ctrl — these are essential for interactive TUIs and barely reachable on a phone keyboard. Most clients hide them in an overflow menu or require two-finger gestures that conflict with terminal mouse reporting. (Remote Desktop Manager offers similar functionality but has the same input limitations.)

### What MobiSSH does differently

1. **Dual input mode.** An IME mode uses a hidden textarea to capture swipe-typed words and voice-dictated text and forwards them to SSH verbatim — no autocorrect interference. A direct mode forwards keystrokes char-by-char for zero-latency response with a Bluetooth keyboard.

2. **Persistent special-key bar.** Ctrl (sticky modifier), Esc, Tab, /, |, -, arrow keys, Home, End, PgUp, PgDn — all one tap away in a horizontally scrollable row. Auto-hides via a tap-toggle strip to give the terminal the full screen.

3. **xterm.js rendering.** Full VT100/VT220 and xterm-256color support. `htop`, `vim`, `tmux`, `claude` — they all render correctly because xterm.js is the same engine used in VS Code and Warp.

4. **PWA install.** No app store. Add to home screen, get an icon, launch fullscreen. Works offline for the shell UI; the SSH bridge needs network.

5. **Tailscale-native.** Designed to connect to servers on a WireGuard mesh. No port exposure to the internet. SSH host key verification is the trust anchor.

---

## Architecture

```
Phone browser ──(WSS)──► Node.js bridge ──(SSH)──► Target server
                              │
              HTTP static file server (same port)
```

- **`server/index.js`** — single Node.js process: serves `public/` over HTTP and bridges WebSocket connections to SSH using `ssh2`. One port (default 8081) for everything.
- **`public/app.js`** — all frontend logic: xterm.js init, WebSocket client, IME input capture, key bar, vault, profile storage.
- **`public/app.css`** — mobile-first styles, no framework.
- **`public/sw.js`** — service worker, network-first with offline fallback. Caches the full app shell including vendored xterm.js.
- **`public/recovery.js`** — boot watchdog + emergency reset. Detects init failures, shows diagnostic errors, breaks reset loops, and provides a long-press escape hatch on the Settings tab.
- **`public/vendor/`** — vendored xterm.js 5.3.0 and xterm-addon-fit 0.8.0 (served locally to avoid CDN/CSP conflicts).

### IME input strategy

MobiSSH has two input modes, toggled via the IME button in the key bar:

**IME mode (default):** A visually hidden `<textarea>` stays focused during terminal sessions. Swipe-typed words and voice-dictated text arrive as `input` events; the full committed string is forwarded to SSH and the textarea is cleared. Composition events (`compositionstart`/`update`/`end`) show a preview strip above the key bar so you can see the word being formed before it commits. Special keys (Escape, arrows, Tab) are intercepted at `keydown` before the IME processes them.

**Direct mode:** A hidden `type="password"` input stays focused instead. Using a password field tells Gboard and other IMEs to disable swipe-to-type, autocorrect, and autocomplete — every keypress is a raw character. Each `keydown` event is forwarded immediately, eliminating IME buffering latency. Best with a Bluetooth keyboard or for interactive TUI commands where every character matters.

The password-type field also suppresses browser password managers (via `autocomplete="off"`, `data-lpignore`, `data-1p-ignore`) to avoid save-password prompts appearing during an SSH session.

### Credential vault

Profiles are stored in `localStorage` without credentials. Credentials (passwords, private keys, passphrases) are AES-GCM encrypted with a 256-bit key derived from one of two browser APIs:

- **Chrome/Android:** `PasswordCredential` — random key stored in the browser's credential store, backed by device biometric / screen lock.
- **Safari/iOS 18+:** WebAuthn PRF — key derived from a passkey via the PRF extension, biometric-gated via Face ID / Touch ID.

On load, a silent unlock attempt restores the vault key. If locked, the app prompts on first profile use. Credentials are **never stored in plaintext** — if neither vault method is available (Firefox, iOS < 18), credentials are simply not persisted and must be entered each session.

---

## Security analysis

**If you run the bridge on a public IP without authentication middleware, the threat model changes significantly — anyone who can reach the bridge port can proxy SSH connections through your server.**

### Trust model

MobiSSH is designed for personal use over a private WireGuard mesh (Tailscale). The threat model is:

- **In scope:** accidental credential exposure via browser storage, SSH MITM on first connect, SSRF from the bridge, XSS in the frontend.
- **Out of scope (delegated to Tailscale):** unauthenticated access to the bridge, traffic interception between phone and server.

### Current controls

| Control | Status | Notes |
|---|---|---|
| AES-GCM credential encryption | ✅ Implemented | Key from `PasswordCredential` (Chrome) or WebAuthn PRF (Safari) |
| WebAuthn PRF vault for iOS | ✅ Implemented | Passkey + biometric key derivation on iOS 18+ (#14) |
| SSH host key verification (TOFU) | ✅ Implemented | Store fingerprint on first connect, warn on mismatch (#5) |
| SSRF prevention | ✅ Implemented | Blocks RFC-1918 / loopback targets (#6) |
| xterm.js bundled locally | ✅ Implemented | Eliminates CDN dependency and proxy CSP conflicts (#104) |
| Content-Security-Policy header | ✅ Implemented | Restricts script/style/connect sources (#8) |
| `ws://` rejected in settings | ✅ Implemented | Only `wss://` accepted for WebSocket URL (#9) |
| WSS (TLS) in Codespaces / reverse proxy | ✅ Inherited | Codespaces enforces HTTPS |
| `Cache-Control: no-store` on all static responses | ✅ Implemented | Prevents credential caching in shared proxies |
| Service worker network-first | ✅ Implemented | No stale credential forms served from cache |
| `autocorrect="off"` on IME textarea | ✅ Implemented | Prevents iOS keyboard logging typed SSH text |
| Direct mode uses `type="password"` input | ✅ Implemented | Suppresses Gboard swipe prediction and autocorrect |
| WS ping/pong keep-alive (25s) | ✅ Implemented | Terminates stale connections, prevents silent drops |
| SSH keepalive (15s interval, max 4 missed) | ✅ Implemented | Drops idle SSH sessions that are no longer alive |
| Vault-or-nothing credential policy | ✅ Implemented | No plaintext fallback — credentials not saved if vault unavailable (#68) |
| SSH keys encrypted via vault | ✅ Implemented | Keys panel uses same AES-GCM vault as profiles (#67, #69) |
| Boot recovery watchdog | ✅ Implemented | 8s timeout detects init failure, shows diagnostics, breaks reset loops (#84, #104) |

No known high or medium severity open risks. See GitHub Issues for UX and feature backlog.

### Transparency and auditability

MobiSSH makes no attempt to interpret, route, or log what you type. The WebSocket bridge (`server/index.js`) forwards raw bytes between the browser and `ssh2`; what goes in comes out unchanged on the other side. There is no command parser, no action log, no proprietary protocol layer.

This matters in contrast to projects that expose AI coding agents over HTTP/WebSocket APIs with custom control planes. Those tools route AI actions through application-specific channels that can obscure what commands are actually running and introduce unauditable control paths. MobiSSH has no such layer — your SSH session is captured by the same standard audit tools (`sshd` logs, `auditd`, shell history) that record any direct SSH connection.

**Threat model summary:** if you can trust SSH, you can trust MobiSSH.

### Trade-offs

**Single-port design (HTTP + WS on one port).** Simplifies Codespaces port forwarding (one forwarded port instead of two). Downside: the static file server and the SSH bridge share the same process — a bug in one can affect the other. For personal use this is acceptable.

**`localStorage` for profile metadata.** IndexedDB would be more appropriate for structured data but `localStorage` is synchronous and has no async edge cases. Profiles contain no secrets (credentials are vault-encrypted separately).

**No authentication on the WebSocket endpoint.** The bridge trusts that anyone who can establish a WebSocket connection is authorized to proxy SSH. On Tailscale this is enforced by the mesh ACLs. On a public network this is a significant open door. Rate limiting (#92) and page-load token authentication (#93) are planned.

**Vanilla JS, no build step.** Means no tree-shaking, no TypeScript safety, no bundler. Acceptable for a focused single-page app; the entire frontend is one JS file that is easy to read and audit.

**xterm.js bundled in `public/vendor/`.** Originally loaded from CDN with SRI hashes, but code-server's reverse proxy CSP blocked cross-origin scripts. Now served locally from the same origin — works behind any proxy, enables offline caching via the service worker, and tightens CSP to `script-src 'self'`.

---

## Setup

Requires Node.js 18+.

```bash
git clone https://github.com/flavordrake/mobissh.git
cd mobissh/server && npm install
npm start
# → Listening on http://0.0.0.0:8081
```

Open `http://localhost:8081` in a browser, or the Codespace forwarded URL. The server has no dependencies outside `server/node_modules` — the `public/` directory is served as static files with no build step.

### Deployment options

**Direct (Tailscale Serve):** Zero-config HTTPS over your WireGuard mesh.

```bash
cd server && npm start                        # listens on 8081
tailscale serve https / http://localhost:8081  # automatic TLS
```

No `BASE_PATH` needed — MobiSSH serves at the root.

**nginx reverse proxy (subpath):** Run MobiSSH at `/ssh/` alongside other services.

```bash
BASE_PATH=/ssh PORT=8081 node server/index.js
```

Add the provided `nginx-ssh-location.conf` inside your HTTPS `server {}` block, then `sudo nginx -s reload`. See `scripts/setup-nginx.sh` for an automated setup.

**Cache busting:** Visit `/clear` (e.g. `https://host/ssh/clear`) to unregister service workers and clear all browser storage. The app also has a boot watchdog that shows a Reset button if initialization fails, and a long-press (1.5s) escape hatch on the Settings tab.

---

## Backlog highlights

See GitHub Issues for the full list.

Recently completed:
- **#104** Bundle xterm.js locally, boot diagnostics, reset loop detection
- **#83, #84** PWA manifest identity (`id: "mobissh"`) + boot recovery watchdog
- **#85** IME composition fix (compositioncancel, textarea value preference)
- **#86** Docker infrastructure (Dockerfile, compose, scripts)
- **#87** Tab button text selection prevention on long-press
- **#89** Key bar key repeat on hold (400ms delay, 80ms interval)
- **#5** SSH host key verification — TOFU with mismatch warning
- **#6–9** Security hardening (SSRF blocklist, CSP header, ws:// rejection)
- **#14** WebAuthn PRF vault for iOS 18+ credential encryption
- **#68** Vault-or-nothing credential policy (no plaintext fallback)
- **#67, #69** SSH keys encrypted via vault
- **#11–13** iOS safe area insets, Apple PWA meta, overscroll-behavior
- **#1, #2, #3** Key bar auto-hide, IME/direct toggle, scrollable key row
- **#10** iOS autocorrect/autocapitalize fixes
- **#29** WS/SSH keep-alive (prevents silent drops)
- **#38** Extra key bar keys (|, -, Home, End, PgUp, PgDn)
- **#40** Session menu controls (reset, clear, Ctrl+C/Z, reconnect)

Key open items:
- **#92** P0: Rate-limit WebSocket upgrades (DoS protection)
- **#93** P1: Authenticate WebSocket upgrade (page-load token)
- **#106** Vault locked on every restart (PasswordCredential unreliable behind proxy)
- **#103** Add `beforeinstallprompt` handler for in-app install button
- **#4, #28** Session persistence + multi-session (planned milestone)
- **#70** Connect screen refactor — profiles as primary action
- **#53** TUI agent rendering/input issues
- **#19–21** Image passthrough (sixel/iTerm2, overlay, ImageAddon)
- **#99** Haptic feedback fires during key bar scroll
- **#90** Optional two-line key bar with grouping
