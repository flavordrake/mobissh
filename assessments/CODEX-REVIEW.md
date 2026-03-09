# Security Report

Primary finding: the project's strongest stated boundary, "preventing unauthorized SSH session initiation," does not hold as implemented.

- `High` WebSocket "auth" is not a real authorization boundary. The server injects a fresh valid WS token into every unauthenticated HTML response, and then only checks that token on upgrade. Any party that can reach the HTTP endpoint can fetch `/`, read the token, and open the SSH bridge. This contradicts the security model in `SECURITY.md`. References: [server/index.js](/home/ra/code/fd/mobissh/server/index.js#L276), [server/index.js](/home/ra/code/fd/mobissh/server/index.js#L325), [SECURITY.md](/home/ra/code/fd/mobissh/SECURITY.md#L16), [SECURITY.md](/home/ra/code/fd/mobissh/SECURITY.md#L28)

- `High` In the recommended Tailscale Serve deployment, WS auth is disabled entirely and there is no `Origin` check. A malicious webpage opened in the user's browser can attempt a cross-origin WebSocket to the MobiSSH endpoint and, if reachable, drive SSH/SFTP actions from that browser context. This is a classic confused-deputy/CSWSH shape. References: [README.md](/home/ra/code/fd/mobissh/README.md#L68), [README.md](/home/ra/code/fd/mobissh/README.md#L103), [server/index.js](/home/ra/code/fd/mobissh/server/index.js#L329)

- `Medium` The SSRF guard is a string-prefix filter, not a network-level restriction. It misses hostnames that resolve to private IPs and several address forms/ranges not covered by the matcher. Because the actual connection happens later via `ssh2`, the claimed "blocks RFC-1918 and loopback" control is bypassable. References: [server/index.js](/home/ra/code/fd/mobissh/server/index.js#L393), [server/index.js](/home/ra/code/fd/mobissh/server/index.js#L504), [SECURITY.md](/home/ra/code/fd/mobissh/SECURITY.md#L18)

- `Medium` Remote clipboard access is enabled by default through the xterm clipboard addon. I’m inferring from the bundled addon code that OSC 52 can request clipboard read/write; that materially increases risk when connecting to untrusted hosts, especially since the app workflow explicitly involves copying tokens and secrets. Browser permission behavior limits exploitability, but the trust expansion is real. References: [public/index.html](/home/ra/code/fd/mobissh/public/index.html#L19), [src/modules/terminal.ts](/home/ra/code/fd/mobissh/src/modules/terminal.ts#L100), [public/vendor/xterm-addon-clipboard.min.js](/home/ra/code/fd/mobissh/public/vendor/xterm-addon-clipboard.min.js#L1), [README.md](/home/ra/code/fd/mobissh/README.md#L21)

- `Low` SFTP downloads are fully buffered in memory before being returned over WS. A large or hostile file can cause avoidable memory pressure or process instability on the bridge. References: [server/index.js](/home/ra/code/fd/mobissh/server/index.js#L155), [server/index.js](/home/ra/code/fd/mobissh/server/index.js#L160)

What held up well: the vault design is materially stronger than the docs suggest, with AES-GCM, PBKDF2 at 600k iterations, no plaintext fallback, and biometric wrapping as an additional unlock path rather than a downgrade. References: [src/modules/vault.ts](/home/ra/code/fd/mobissh/src/modules/vault.ts#L16), [src/modules/vault.ts](/home/ra/code/fd/mobissh/src/modules/vault.ts#L47), [src/modules/vault.ts](/home/ra/code/fd/mobissh/src/modules/vault.ts#L281)

## Priority fixes

1. Make WS authorization real: require an authenticated session/cookie or a one-time server-side nonce bound to a session, not a token handed to anonymous GETs.
2. In `TS_SERVE=1`, add strict `Origin` validation and preferably an additional nonce/cookie check.
3. Replace `isPrivateHost()` with post-DNS resolution IP enforcement, including IPv6, mapped IPv4, link-local, CGNAT, and rebinding-safe checks.
4. Disable clipboard addon by default or restrict it to write-only with explicit user opt-in.
5. Stream SFTP transfers with size caps instead of buffering whole files.

## Review notes

This was a static code review; I did not run dynamic tests because local server dependencies were not installed in this workspace. I also did not perform a fresh external CVE audit of dependencies.
