# MobiSSH

A mobile-first SSH PWA (Progressive Web App) with a WebSocket bridge. Install to your Android or iOS home screen and use it like a native app over Tailscale or any network.

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

2. **Persistent special-key bar.** Ctrl (sticky modifier), Esc, Tab, /, and arrow keys are always one tap away. The bar is two rows so status lives separately from keys. It auto-hides via a tap-toggle strip to give the terminal the full screen.

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

Android and iOS soft keyboards fire standard DOM `input` events on any focused editable element. MobiSSH keeps a visually hidden `<textarea>` focused during terminal sessions. Swipe-typed words and voice-dictated text arrive as `input` events; the full string is forwarded to SSH and the textarea is cleared. Special keys (Escape, arrows, Tab) are intercepted at `keydown` before the IME processes them.

Direct mode skips the `input` event entirely and forwards each `keydown` character immediately. This eliminates IME buffering latency at the cost of swipe/voice support — useful with a Bluetooth keyboard.

### Credential vault

Profiles are stored in `localStorage` without credentials. Credentials are AES-GCM encrypted with a 256-bit key that lives in `navigator.credentials` (Android Chrome: backed by device biometric / screen lock). On load, a silent `credentials.get` attempts to restore the vault key without user interaction. If locked, the app prompts on first profile use.

**iOS caveat:** `PasswordCredential` is not supported in Safari. A WebAuthn fallback is planned (issue #14). Until then, credentials are not persisted on iOS.

---

## Security analysis

### Trust model

MobiSSH is designed for personal use over a private WireGuard mesh (Tailscale). The threat model is:

- **In scope:** accidental credential exposure via browser storage, SSH MITM on first connect, SSRF from the bridge, XSS in the frontend.
- **Out of scope (delegated to Tailscale):** unauthenticated access to the bridge, traffic interception between phone and server.

If you run the bridge on a public IP without authentication middleware, the threat model changes significantly — anyone who can reach port 8080 can proxy SSH connections through your server.

### Current controls

| Control | Status | Notes |
|---|---|---|
| AES-GCM credential encryption | ✅ Implemented | Key in `PasswordCredential` / biometric |
| WSS (TLS) in Codespaces / reverse proxy | ✅ Inherited | Codespaces enforces HTTPS |
| `Cache-Control: no-store` on all static responses | ✅ Implemented | Prevents credential caching in shared proxies |
| Service worker network-first | ✅ Implemented | No stale credential forms served from cache |
| `autocorrect="off"` on IME textarea | ✅ Implemented | Prevents iOS keyboard logging typed SSH text |

### Open risks (filed as issues)

| Risk | Severity | Issue |
|---|---|---|
| SSH host key not verified — MITM possible on first connect | **High** | #5 |
| No SSRF prevention — bridge will connect to RFC-1918 addresses | Medium | #6 |
| xterm.js loaded from CDN without SRI hashes | Medium | #7 |
| No Content-Security-Policy header | Medium | #8 |
| `ws://` (plaintext WebSocket) accepted in settings | Low | #9 |
| `PasswordCredential` not available on iOS — creds not persisted | Low | #14 |

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

- **#5** SSH host key verification (highest real security risk)
- **#4** Multi-session tab support
- **#14** WebAuthn vault path for iOS
- **#1–3** Key bar UX (auto-hide, two-row layout, IME/direct toggle) — ✅ done
- **#10–13** iOS compatibility (autocorrect attrs, safe area, Apple PWA meta)
