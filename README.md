# MobiSSH

A mobile-first SSH PWA (Progressive Web App) with a WebSocket bridge. Install to your Android or iOS home screen and use it like a native app over Tailscale or any network.

> **Not a remote agent controller.** MobiSSH is standard SSH, made mobile-friendly. The bridge is a thin WebSocket proxy — it forwards bytes between your browser and the SSH server, nothing more. No command interception, no custom control plane, no proprietary protocol.

---

## Why this exists

Most mobile SSH clients fail the same way: they treat the terminal as a text viewer with a keyboard bolted on. That works for quick `ls` or reading a log file. It breaks down the moment you open `vim`, `htop`, `tmux`, or Claude Code.

### The specific problems with existing mobile SSH apps

**Highly interactive TUI apps depend on exact key sequences.** `vim` enters insert mode on `i`, exits on `Esc`, saves with `:wq`. `tmux` multiplexes windows with `Ctrl-b c`. `htop` sorts columns with arrow keys. Every one of these depends on the app receiving a precise byte sequence — not an autocorrected, swipe-predicted, autocapitalized string.

Android and iOS soft keyboards were designed for messaging apps. When you type in a messaging app, autocorrect is your friend. When you type `ggVGy` in a vim window, autocorrect is catastrophic.

**Existing clients solve the key-sequence problem but break IME input.** Apps like JuiceSSH or Termius disable autocorrect globally, which means you lose swipe-to-type, voice dictation, and predictive text — the features that make typing long text on a phone bearable. Writing a commit message or a comment in an SSH session becomes hunt-and-peck.

**No existing client exposes a configurable special-key bar.** Arrow keys, Escape, Tab, Ctrl — these are essential for interactive TUIs and barely reachable on a phone keyboard. Most clients hide them in an overflow menu or require two-finger gestures that conflict with terminal mouse reporting.

**Notch, safe area, and keyboard-resize handling is inconsistent.** Native apps sometimes get this right. Web-based clients almost never do.

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
              HTTP static file server (same port 8080)
```

- **`server/index.js`** — single Node.js process: serves `public/` over HTTP and bridges WebSocket connections to SSH using `ssh2`. One port (8080) for everything.
- **`public/app.js`** — all frontend logic: xterm.js init, WebSocket client, IME input capture, key bar, vault, profile storage.
- **`public/app.css`** — mobile-first styles, no framework.
- **`public/sw.js`** — service worker, network-first with offline fallback.

### IME input strategy

MobiSSH has two input modes, toggled via the IME button in the key bar:

**IME mode (default):** A visually hidden `<textarea>` stays focused during terminal sessions. Swipe-typed words and voice-dictated text arrive as `input` events; the full committed string is forwarded to SSH and the textarea is cleared. Composition events (`compositionstart`/`update`/`end`) show a preview strip above the key bar so you can see the word being formed before it commits. Special keys (Escape, arrows, Tab) are intercepted at `keydown` before the IME processes them.

**Direct mode:** A hidden `type="password"` input stays focused instead. Using a password field tells Gboard and other IMEs to disable swipe-to-type, autocorrect, and autocomplete — every keypress is a raw character. Each `keydown` event is forwarded immediately, eliminating IME buffering latency. Best with a Bluetooth keyboard or for interactive TUI commands where every character matters.

The password-type field also suppresses browser password managers (via `autocomplete="off"`, `data-lpignore`, `data-1p-ignore`) to avoid save-password prompts appearing during an SSH session.

### Credential vault

Profiles are stored in `localStorage` without credentials. Credentials are AES-GCM encrypted with a 256-bit key that lives in `navigator.credentials` (Android Chrome: backed by device biometric / screen lock). On load, a silent `credentials.get` attempts to restore the vault key without user interaction. If locked, the app prompts on first profile use.

**iOS caveat:** `PasswordCredential` is not supported in Safari. A WebAuthn fallback is planned (issue #14). Until then, credentials are not persisted on iOS.

---

## Security analysis

**If you run the bridge on a public IP without authentication middleware, the threat model changes significantly — anyone who can reach port 8080 can proxy SSH connections through your server.**

### Trust model

MobiSSH is designed for personal use over a private WireGuard mesh (Tailscale). The threat model is:

- **In scope:** accidental credential exposure via browser storage, SSH MITM on first connect, SSRF from the bridge, XSS in the frontend.
- **Out of scope (delegated to Tailscale):** unauthenticated access to the bridge, traffic interception between phone and server.

### Current controls

| Control | Status | Notes |
|---|---|---|
| AES-GCM credential encryption | ✅ Implemented | Key in `PasswordCredential` / biometric |
| WSS (TLS) in Codespaces / reverse proxy | ✅ Inherited | Codespaces enforces HTTPS |
| `Cache-Control: no-store` on all static responses | ✅ Implemented | Prevents credential caching in shared proxies |
| Service worker network-first | ✅ Implemented | No stale credential forms served from cache |
| `autocorrect="off"` on IME textarea | ✅ Implemented | Prevents iOS keyboard logging typed SSH text |
| Direct mode uses `type="password"` input | ✅ Implemented | Suppresses Gboard swipe prediction and autocorrect |
| WS ping/pong keep-alive (25s) | ✅ Implemented | Terminates stale connections, prevents silent drops |
| SSH keepalive (15s interval, max 4 missed) | ✅ Implemented | Drops idle SSH sessions that are no longer alive |

### Open risks (filed as issues)

| Risk | Severity | Issue |
|---|---|---|
| SSH host key not verified — MITM possible on first connect | **High** | #5 |
| No SSRF prevention — bridge will connect to RFC-1918 addresses | Medium | #6 |
| xterm.js loaded from CDN without SRI hashes | Medium | #7 |
| No Content-Security-Policy header | Medium | #8 |
| `ws://` (plaintext WebSocket) accepted in settings | Low | #9 |
| `PasswordCredential` not available on iOS — creds not persisted | Low | #14 |

### Transparency and auditability

MobiSSH makes no attempt to interpret, route, or log what you type. The WebSocket bridge (`server/index.js`) forwards raw bytes between the browser and `ssh2`; what goes in comes out unchanged on the other side. There is no command parser, no action log, no proprietary protocol layer.

This matters in contrast to projects that expose AI coding agents over HTTP/WebSocket APIs with custom control planes. Those tools route AI actions through application-specific channels that can obscure what commands are actually running and introduce unauditable control paths. MobiSSH has no such layer — your SSH session is captured by the same standard audit tools (`sshd` logs, `auditd`, shell history) that record any direct SSH connection.

**Threat model summary:** if you can trust SSH, you can trust MobiSSH.

### Trade-offs

**Single-port design (HTTP + WS on 8080).** Simplifies Codespaces port forwarding (one forwarded port instead of two). Downside: the static file server and the SSH bridge share the same process — a bug in one can affect the other. For personal use this is acceptable.

**`localStorage` for profile metadata.** IndexedDB would be more appropriate for structured data but `localStorage` is synchronous and has no async edge cases. Profiles contain no secrets (credentials are vault-encrypted separately).

**No authentication on the WebSocket endpoint.** The bridge trusts that anyone who can establish a WebSocket connection is authorized to proxy SSH. On Tailscale this is enforced by the mesh ACLs. On a public network this is a significant open door — adding HTTP basic auth or a bearer token to the upgrade handshake is the correct fix.

**Vanilla JS, no build step.** Means no tree-shaking, no TypeScript safety, no bundler. Acceptable for a focused single-page app; the entire frontend is one JS file that is easy to read and audit.

**xterm.js from CDN.** Fast to set up, but the integrity of the terminal emulator depends on the CDN. SRI hashes (issue #7) would pin the version cryptographically.

---

## Setup

```bash
# Install server dependencies
cd server && npm install

# Start the bridge
npm start
# → Listening on http://0.0.0.0:8080

# Open http://localhost:8080 in Chrome on Android
# or the Codespace forwarded URL
```

Over Tailscale, point the Settings → WebSocket URL at `wss://your-tailscale-hostname:8080` (or `ws://` if TLS terminates elsewhere).

---

## Backlog highlights

See GitHub Issues for the full list. Key open items:

Recently completed:
- **#22** Rename to MobiSSH
- **#29** WS/SSH keep-alive (prevents silent drops)
- **#38** Extra key bar keys (|, -, Home, End, PgUp, PgDn)
- **#40** Session menu controls (reset, clear, Ctrl+C/Z, reconnect)
- **#50** Removed broken WebLinksAddon
- **#1, #2, #3** Key bar auto-hide, IME/direct toggle, scrollable key row
- **#10** iOS autocorrect/autocapitalize fixes

Key open items:
- **#5** SSH host key verification (highest real security risk)
- **#4** Multi-session tab support
- **#14** WebAuthn vault path for iOS
- **#6–9** Security hardening (SSRF, SRI, CSP, ws:// block)
- **#11–13** iOS safe area, Apple PWA meta, standalone
- **#37** Touch scroll / tmux mouse protocol
