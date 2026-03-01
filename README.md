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

1. **Dual input mode.** Direct mode forwards keystrokes char-by-char for zero-latency TUI interaction. Compose mode uses a hidden textarea to capture swipe-typed words and voice-dictated text and forwards them to SSH verbatim — no autocorrect interference.

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
- **`src/modules/*.ts`** — frontend source in TypeScript (strict mode). Compiled via `tsc` to `public/modules/*.js` as ES modules.
- **`public/app.js`** — entry point that imports the compiled modules.
- **`public/app.css`** — mobile-first styles, no framework.
- **`public/sw.js`** — service worker, network-first with offline fallback. Caches the full app shell including vendored xterm.js.
- **`public/recovery.js`** — boot watchdog + emergency reset. Detects init failures, shows diagnostic errors, breaks reset loops, and provides a long-press escape hatch on the Settings tab.
- **`public/vendor/`** — vendored @xterm/xterm 6.0.0 and @xterm/addon-fit 0.11.0 (served locally to avoid CDN/CSP conflicts).

### IME input strategy

MobiSSH has two input modes, toggled via the compose button in the key bar:

**Direct mode (default):** A hidden `type="password"` input stays focused. Using a password field tells Gboard and other IMEs to disable swipe-to-type, autocorrect, and autocomplete — every keypress is a raw character. Each `keydown` event is forwarded immediately, eliminating IME buffering latency. Best for interactive TUI commands and Bluetooth keyboards.

**Compose mode:** A visually hidden `<textarea>` stays focused instead. Swipe-typed words and voice-dictated text arrive as `input` events; the full committed string is forwarded to SSH and the textarea is cleared. Composition events (`compositionstart`/`update`/`end`) show a preview strip above the key bar so you can see the word being formed before it commits. Special keys (Escape, arrows, Tab) are intercepted at `keydown` before the IME processes them. Best for writing long text like commit messages.

The password-type field also suppresses browser password managers (via `autocomplete="off"`, `data-lpignore`, `data-1p-ignore`) to avoid save-password prompts appearing during an SSH session.

### Credential vault

Profiles are stored in `localStorage` without credentials. Credentials (passwords, private keys, passphrases) are AES-GCM encrypted with a 256-bit key derived from one of two browser APIs:

- **Chrome/Android:** `PasswordCredential` — random key stored in the browser's credential store, backed by device biometric / screen lock.
- **Safari/iOS 18+:** WebAuthn PRF — key derived from a passkey via the PRF extension, biometric-gated via Face ID / Touch ID.

On load, a silent unlock attempt restores the vault key. If locked, the app prompts on first profile use. Credentials are **never stored in plaintext** — if neither vault method is available (Firefox, iOS < 18), credentials are simply not persisted and must be entered each session.

---

## Security

**If you run the bridge on a public IP without additional network controls, anyone who can reach the port can proxy SSH connections through your server.** MobiSSH is designed for personal use over a private WireGuard mesh (Tailscale).

### Threat model

- **In scope:** credential exposure via browser storage, SSH MITM on first connect, SSRF from the bridge, XSS in the frontend.
- **Out of scope (delegated to Tailscale):** network-level access control, traffic interception between phone and server.

### Controls

**Credential storage.** Passwords, private keys, and passphrases are AES-GCM encrypted with a 256-bit key. On Chrome/Android the key lives in `PasswordCredential` (biometric-gated). On Safari/iOS 18+ it's derived from a passkey via WebAuthn PRF (Face ID / Touch ID). If neither vault is available, credentials are not persisted at all — no plaintext fallback.

**SSH host key verification.** TOFU (trust on first use). The fingerprint is stored on first connect; subsequent connections warn on mismatch.

**SSRF prevention.** The bridge blocks connections to RFC-1918 and loopback addresses.

**WebSocket authentication.** Each page load generates an HMAC token; the WS upgrade must present a valid, unexpired token.

**Transport.** Only `wss://` is accepted for WebSocket URLs. `Cache-Control: no-store` on all static responses. Service worker is network-first (no stale forms served from cache).

**CSP.** `Content-Security-Policy` header restricts script, style, and connect sources. xterm.js is bundled locally (`public/vendor/`) to avoid CDN dependencies and tighten CSP to `script-src 'self'`.

**IME privacy.** Direct mode uses `type="password"` to suppress Gboard prediction at the OS level. Compose mode textarea has `autocorrect="off"` to prevent iOS keyboard logging.

**Connection health.** WS ping/pong every 25s terminates stale connections. SSH keepalive every 15s (max 4 missed) drops dead sessions.

**Boot recovery.** 8-second watchdog detects init failures, shows diagnostics, breaks reset loops, and provides an emergency cache-clear path.

### Transparency

The WebSocket bridge forwards raw bytes between the browser and `ssh2`. There is no command parser, no action log, no proprietary protocol layer. Your SSH session is captured by the same standard audit tools (`sshd` logs, `auditd`, shell history) as any direct SSH connection.

### Trade-offs

**Single-port design.** HTTP static server and WS bridge share one Node.js process on one port. Simplifies deployment and port forwarding. A bug in one can affect the other; acceptable for personal use.

**`localStorage` for profile metadata.** Synchronous and simple. Profiles contain no secrets — credentials are vault-encrypted separately.

**TypeScript with tsc compilation.** Source lives in `src/modules/*.ts`, compiled output served from `public/modules/*.js`. No heavy bundler (webpack, vite). Adds a build step but provides strict type checking and static analysis.

### Claude security review (v0.4.0, Feb 2026)

Automated review of 37 commits (v0.3.0..v0.4.0) covering WebSocket HMAC authentication, input mode changes, hash-based routing, credential field cloaking, recording UI, and documentation updates. **No high-confidence vulnerabilities found.**

Areas examined and results:

- **WebSocket authentication** (`server/index.js`): HMAC-SHA256 with per-boot secret, timing-safe comparison, timestamp expiry. Sound implementation.
- **SSRF prevention** (`server/index.js`): RFC-1918 and loopback blocking intact, no bypass introduced.
- **Credential handling** (`vault.ts`, `profiles.ts`, `ui.ts`): AES-GCM encryption unchanged, no plaintext credential storage introduced.
- **XSS surface** (`profiles.ts`, `connection.ts`, `ui.ts`): `escHtml()` used consistently for dynamic content. Hash routing validates against `VALID_PANELS` whitelist.
- **Static file serving** (`server/index.js`): No path traversal vectors introduced.
- **Input handling** (`ime.ts`): `beforeinput` interception and direct mode changes are DOM-only with no injection surface.

---

## Setup

Requires Node.js 18+.

```bash
git clone https://github.com/flavordrake/mobissh.git
cd mobissh/server && npm install
npm start
# → Listening on http://0.0.0.0:8081
```

Open `http://localhost:8081` in a browser, or the Codespace forwarded URL. The server has no dependencies outside `server/node_modules`. Frontend TypeScript is pre-compiled; the `public/` directory is served as static files.

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

