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

## Security review (latest)

### Claude security review

  No high-confidence security vulnerabilities found.

  Review scope: Full codebase scan of server/index.js
  (HTTP/WS/SSH/SFTP server), src/modules/*.ts (frontend), and
  public/sw.js (service worker).

  Positive security controls observed:
  - HMAC-SHA256 WS token: anti-automation measure with timingSafeEqual() comparison (not session auth)
  - AES-GCM vault with PBKDF2 key derivation (600k iterations)
  - SSRF blocking: post-DNS IP range validation covers RFC-1918, loopback, link-local, CGNAT, and IPv4-mapped IPv6
  - escHtml() used consistently on user-supplied content in double-quoted attributes
  - SFTP paths passed to ssh2 library without shell interpretation
  - Cache-Control: no-store on all responses
  - CSS.escape() for dynamic selectors
  - No plaintext credential fallback path

## Known limitations

- `PasswordCredential` API is Chrome/Android only. Safari, Firefox, and iOS do not support it. Credential persistence on these platforms requires the WebAuthn PRF path (#2).
- The HMAC WS token is transmitted in the WebSocket URL query string. Over WSS (TLS) this is encrypted in transit, but may appear in server access logs. The token is an anti-automation measure; Tailscale's encrypted tunnel provides the real access control layer.
- Service worker caches the app shell for offline use. `Cache-Control: no-store` and network-first strategy prevent serving stale authenticated content, but the offline shell itself is cached.

## Reporting vulnerabilities

This is a personal project. If you find a security issue, please open a GitHub issue or contact the maintainer directly.
