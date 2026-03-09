# Security

MobiSSH is designed for personal use over Tailscale (WireGuard mesh). The bridge runs on your private network -- not exposed to the internet.

## Credential vault

Passwords, private keys, and passphrases are AES-GCM encrypted with a 256-bit key:

- **Chrome/Android:** `PasswordCredential` -- biometric / screen lock gated
- **No vault available:** credentials are not persisted at all. No plaintext fallback, ever.

iOS credential persistence requires a WebAuthn PRF implementation (tracked in issue #2). Until then, iOS users must re-enter credentials each session.

## Transport and access control

- WebSocket upgrade requires HMAC token (per-boot secret, timing-safe, expiring)
- `Cache-Control: no-store` on all responses. Network-first service worker.
- SSRF prevention blocks RFC-1918 and loopback addresses
- SSH host key TOFU with mismatch warnings
- CSP restricts all script/style/connect sources. xterm.js vendored locally for `script-src 'self'`

## Transparency

The bridge forwards raw bytes. No command parser, no action log, no telemetry. Your SSH session is captured by the same standard audit tools (`sshd` logs, `auditd`, shell history) as any direct connection.

## Threat model

**In scope:** protecting credentials at rest, preventing unauthorized SSH session initiation, preventing XSS/injection in the terminal UI, ensuring transport integrity.

**Out of scope:** network-level attacks (delegated to Tailscale/WireGuard), compromised SSH target servers, physical device compromise.

## Security review (v0.4.0)

Automated review of 37 commits covering WS auth, input modes, routing, credential handling. No high-confidence vulnerabilities found.

**Findings:**
- HMAC-SHA256 WS auth: timing-safe comparison, per-boot secret rotation, token expiry -- sound
- SSRF blocking: RFC-1918 and loopback address filtering intact
- AES-GCM vault: 256-bit key derivation, no plaintext fallback path -- sound
- XSS prevention: `escHtml()` used consistently on all user-supplied content rendered to DOM
- Path traversal: static file server normalizes paths and validates against PUBLIC_DIR -- no vectors found
- IME injection: compose mode textarea content is sent as raw bytes to SSH, not interpreted as HTML -- no injection surface
- CSP: `script-src 'self'`, `style-src 'self'`, `connect-src 'self' wss:` -- restrictive and correct

## Known limitations

- `PasswordCredential` API is Chrome/Android only. Safari, Firefox, and iOS do not support it. Credential persistence on these platforms requires the WebAuthn PRF path (#2).
- The HMAC WS auth token is transmitted in the WebSocket URL query string. Over WSS (TLS) this is encrypted in transit, but may appear in server access logs. Tailscale's encrypted tunnel provides the primary transport security layer.
- Service worker caches the app shell for offline use. `Cache-Control: no-store` and network-first strategy prevent serving stale authenticated content, but the offline shell itself is cached.

## Reporting vulnerabilities

This is a personal project. If you find a security issue, please open a GitHub issue or contact the maintainer directly.
