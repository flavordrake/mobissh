# Security

MobiSSH is designed for personal use over Tailscale (WireGuard mesh). The bridge runs on your private network -- not exposed to the internet.

## Credential vault

Passwords, private keys, and passphrases are AES-GCM encrypted with a 256-bit key:

- **Chrome/Android:** `PasswordCredential` -- biometric / screen lock gated
- **No vault available:** credentials are not persisted at all. No plaintext fallback, ever.

iOS credential persistence requires a WebAuthn PRF implementation (tracked in issue #2). Until then, iOS users must re-enter credentials each session.

## Transport and access control

- WebSocket upgrade includes an HMAC token (per-boot secret, timing-safe, expiring). This is an anti-automation measure, not session authentication -- any client that can reach the HTTP endpoint can obtain a token. Real access control is provided by the network layer (Tailscale).
- Origin header validation prevents cross-site WebSocket hijacking (CSWSH) from malicious webpages.
- `Cache-Control: no-store` on all responses. Network-first service worker.
- SSRF prevention blocks private/reserved IP ranges (post-DNS resolution)
- SSH host key TOFU with mismatch warnings
- CSP restricts all script/style/connect sources. xterm.js vendored locally for `script-src 'self'`

## Transparency

The bridge forwards raw bytes. No command parser, no action log, no telemetry. Your SSH session is captured by the same standard audit tools (`sshd` logs, `auditd`, shell history) as any direct connection.

## Threat model

**In scope:** protecting credentials at rest, preventing unauthorized SSH session initiation, preventing XSS/injection in the terminal UI, ensuring transport integrity.

**Out of scope:** network-level attacks (delegated to Tailscale/WireGuard), compromised SSH target servers, physical device compromise.

## External security assessments

Two independent static reviews were conducted in March 2026. Full reports are in [`assessments/`](assessments/):

- [Codex review](assessments/CODEX-REVIEW.md) -- 5 findings (2 High, 2 Medium, 1 Low)
- [Gemini review](assessments/GEMINI-REVIEW.md) -- 4 findings (1 Medium, 3 Low)

Both reviews independently flagged CSWSH and SSRF as the top actionable issues. Both praised the vault implementation.

### Actions taken

| Finding | Severity | Action | Status |
|---------|----------|--------|--------|
| CSWSH: no Origin check when `TS_SERVE=1` | High/Medium | Added Origin header validation in `verifyClient` (`server/origin.js`) | Fixed (#83) |
| SSRF: string-prefix bypass via DNS rebinding | Medium/Low | Replaced with post-DNS `isPrivateIp()` using numeric CIDR matching | Fixed (#84) |
| Clipboard: OSC 52 addon loaded unconditionally | Medium | Disabled by default; opt-in toggle in Settings > Danger Zone | Fixed (#85) |
| WS token described as auth boundary | High | Revised docs to clarify it's anti-automation, not session auth | Fixed |
| SFTP downloads buffered in memory | Low | Accepted risk; streaming would limit full-featured SFTP functionality | Won't fix |
| Root container execution | Low | Required for embedded Tailscale daemon; standard for this architecture | Accepted |
| Insecure transport (non-VPN) | Low | Already mitigated: UI warning + Tailscale default deployment | No change needed |

### Positive findings (both reviews)

- AES-GCM vault with PBKDF2 (600k iterations), no plaintext fallback
- HMAC-SHA256 WS token with timingSafeEqual() comparison
- escHtml() used consistently on user-supplied DOM content
- Restrictive CSP: `script-src 'self'`, `style-src 'self'`, `frame-ancestors 'none'`
- Small dependency footprint (ssh2, ws, xterm.js) -- all current
- SFTP paths passed to ssh2 without shell interpretation
- Cache-Control: no-store on all responses

## Known limitations

- `PasswordCredential` API is Chrome/Android only. Safari, Firefox, and iOS do not support it. Credential persistence on these platforms requires the WebAuthn PRF path (#2).
- The HMAC WS token is transmitted in the WebSocket URL query string. Over WSS (TLS) this is encrypted in transit, but may appear in server access logs. The token is an anti-automation measure; Tailscale's encrypted tunnel provides the real access control layer.
- Service worker caches the app shell for offline use. `Cache-Control: no-store` and network-first strategy prevent serving stale authenticated content, but the offline shell itself is cached.

## Reporting vulnerabilities

This is a personal project. If you find a security issue, please open a GitHub issue or contact the maintainer directly.
