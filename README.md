# MobiSSH

Mobile command and control for coding agents over SSH. Swipe-type prompts, dictate instructions, upload screenshots, paste docs into context, manage tokens and URLs -- all from your phone, with the full power of a real terminal underneath.

> **Standard SSH, mobile-native UX.** The bridge is a thin WebSocket proxy that forwards bytes between your browser and the SSH server. No command interception, no proprietary protocol. Your agents (Claude Code, OpenCode, Gemini CLI, Codex) run in their normal SSH environment.

## The workflow

You're on your phone. You have an idea, a bug report, a screenshot of broken UI. You want to tell your coding agent what to do, review its output, iterate -- without opening a laptop.

**Compose mode** is the core of this. Tap the compose button, and MobiSSH switches from raw terminal input to a native mobile text field. Swipe-type a multi-sentence prompt. Dictate a paragraph with voice input. Edit, review, then send. The agent receives clean text, not the garbled output of autocorrect fighting a terminal emulator.

**Direct mode** is always one tap away for when you need raw keystrokes -- navigating tmux, scrolling agent output, sending Ctrl-C to stop a runaway process.

### What you can do from your phone

**Drive coding agents.** Launch `claude`, `opencode`, `gemini`, or `codex` over SSH. Compose long prompts with swipe or voice. Review diffs in the terminal. Approve or reject changes. The full agent TUI renders correctly -- xterm.js is the same engine as VS Code's terminal.

**Upload context.** Take a screenshot of a bug, a photo of a whiteboard, a screen recording. Upload it through the Files panel via SFTP directly to the remote machine where your agent can read it. No email-to-self, no cloud drive sync, no waiting.

**Manage credentials.** Copy a GitHub token from your password manager, paste it into the terminal. Copy a URL from your browser, paste it into a prompt. MobiSSH's paste button detects clipboard content and sends it to the active session. Vault-encrypted credential storage means your SSH passwords and keys are biometric-locked, not plaintext.

**Multiplex sessions.** Swipe horizontally to switch tmux windows. Swipe vertically to scroll output. Pinch to zoom the font. One-tap key bar for Ctrl, Esc, Tab, arrows, PgUp/PgDn. All designed for one-handed phone use.

## Security

MobiSSH is designed for personal use over Tailscale (WireGuard mesh). The bridge runs on your private network -- not exposed to the internet.

### Credential vault

Passwords, private keys, and passphrases are AES-GCM encrypted with a 256-bit key:

- **Chrome/Android:** `PasswordCredential` -- biometric / screen lock gated
- **Safari/iOS 18+:** WebAuthn PRF -- Face ID / Touch ID gated
- **No vault available:** credentials are not persisted at all. No plaintext fallback, ever.

### Transport and access control

- WebSocket upgrade requires HMAC token (per-boot secret, timing-safe, expiring)
- Only `wss://` accepted. `Cache-Control: no-store` on all responses. Network-first service worker.
- SSRF prevention blocks RFC-1918 and loopback addresses
- SSH host key TOFU with mismatch warnings
- CSP restricts all script/style/connect sources. xterm.js vendored locally for `script-src 'self'`

### Transparency

The bridge forwards raw bytes. No command parser, no action log, no telemetry. Your SSH session is captured by the same standard audit tools (`sshd` logs, `auditd`, shell history) as any direct connection.

### Security review (v0.4.0)

Automated review of 37 commits covering WS auth, input modes, routing, credential handling. No high-confidence vulnerabilities found. Details: HMAC-SHA256 WS auth sound, SSRF blocking intact, AES-GCM vault unchanged, `escHtml()` used consistently, no path traversal vectors, no injection surface in IME handling.

## Architecture

```
Phone browser --(WSS)--> Node.js bridge --(SSH)--> Target server
                              |
              HTTP static file server (same port)
```

- **`server/index.js`** -- single Node.js process: HTTP + WebSocket SSH bridge on one port (default 8081)
- **`src/modules/*.ts`** -- frontend TypeScript (strict mode), compiled via `tsc` to `public/modules/*.js`
- **`public/app.css`** -- mobile-first styles, CSS custom properties for theming
- **`public/sw.js`** -- service worker, network-first with offline app shell fallback
- **`public/recovery.js`** -- boot watchdog + emergency reset (8s timeout, long-press escape hatch)
- **`public/vendor/`** -- vendored @xterm/xterm 6.0.0 and @xterm/addon-fit 0.11.0

### Input modes

**Direct mode (default):** Hidden `type="password"` input suppresses IME autocorrect/swipe at the OS level. Every keypress forwarded immediately. Best for TUI navigation, vim, tmux, agent control sequences.

**Compose mode:** Hidden `<textarea>` captures swipe-typed words and voice dictation. Composition preview shows the word being formed. Full string sent on commit. Best for writing prompts, commit messages, long-form text to coding agents.

## Setup

### Docker (recommended)

```bash
git clone https://github.com/flavordrake/mobissh.git
cd mobissh

export TS_AUTHKEY="tskey-auth-..."
export TS_HOSTNAME="mobissh"

docker compose -f docker-compose.prod.yml up -d
```

The container joins your Tailscale network, serves HTTPS via `tailscale serve`, and restarts automatically. Access at `https://<TS_HOSTNAME>.<tailnet>/ssh/`.

Rebuild after changes:
```bash
docker compose -f docker-compose.prod.yml build && docker compose -f docker-compose.prod.yml up -d
```

### Local (development / testing)

```bash
cd server && npm install && npm start
# Listening on http://0.0.0.0:8081
```

### Termux (Android)

Run MobiSSH directly on your phone with [Termux](https://termux.dev):

```bash
pkg install nodejs-lts git
git clone https://github.com/flavordrake/mobissh.git
cd mobissh/server && npm install && npm start
```

Open `http://localhost:8081` in your device browser. To keep the server running when the screen is off:

```bash
termux-wake-lock
npm start
```

Use `termux-open http://localhost:8081` to launch the browser from Termux. To connect to other machines on your network, use their Tailscale IP as the SSH host.

### Other options

**Tailscale Serve (no Docker):** `cd server && npm start` then `tailscale serve https / http://localhost:8081`

**nginx subpath:** `BASE_PATH=/ssh PORT=8081 node server/index.js` with `nginx-ssh-location.conf`. See `scripts/setup-nginx.sh`.

**Cache busting:** Visit `/clear` to unregister service workers and wipe storage. Boot watchdog shows Reset on init failure. Long-press (1.5s) Settings tab for emergency reset.

## Development

### Build

`npx tsc` compiles `src/modules/*.ts` to `public/modules/*.js`. No bundler.

### Testing

| Layer | What it covers | Command |
|---|---|---|
| Type check + lint + unit | Fast pre-commit gate | `scripts/test-typecheck.sh && scripts/test-lint.sh && scripts/test-unit.sh` |
| Headless browser | UI rendering, navigation, vault, forms | `scripts/test-headless.sh` |
| Android emulator (Appium) | Touch gestures, real Chrome, screen recording | `scripts/run-appium-tests.sh` |
| Manual device | iOS, biometric, Bluetooth keyboard | On-device |

### Bot delegation

Issues labeled `bot` are worked by the Claude Code GitHub integration. `/delegate` classifies and assigns; `/integrate` gates and merges. Process details in `.claude/process.md`.

## License

MIT. See [LICENSE](LICENSE).
