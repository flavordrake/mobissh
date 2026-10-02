# Security

MobiSSH is an SSH client: it connects straight from the device to your server with dartssh2. No relay or proxy of the developer's sits in that path. It is built for personal use, typically over Tailscale (WireGuard mesh).

## Secrets on the device

- Passwords, private keys and passphrases are stored through `flutter_secure_storage` (`native/lib/storage/secrets_store.dart`): Android Keystore-backed encrypted preferences, the Apple Keychain on macOS, libsecret on Linux. When secure storage is unavailable the feature is blocked; there is no plaintext fallback.
- Profiles hold no secrets; they reference a secret or a key in the key library by id.
- There is no biometric gate today. Unlocking the device is what protects the stored secrets.
- Encrypted backup (`native/lib/storage/backup.dart`) seals everything in one file with AES-256-GCM under an Argon2id key derived from a passphrase of 12 or more characters. The ssh_config export contains no secrets.

## Host keys

- First contact shows the server's SHA256 fingerprint and asks you to trust it (trust on first use). Fingerprints are public data and are kept in SharedPreferences (`native/lib/ssh/host_key_store.dart`).
- A changed key refuses to connect. The Review screen shows the old and new fingerprints with a MITM warning; "Forget old key and reconnect" removes only that host:port, and the new key still goes through the first-contact prompt. Jump hosts are checked hop by hop.
- Keys stored before the SHA256 switch (MD5) get a one-time re-confirm prompt.

## What leaves the device besides SSH

- **Bug reports** you choose to send, after a Review & Send screen that lets you drop the screenshots and traces. Text logs pass through a best-effort secret scrubber (`native/lib/diagnostics/feedback_bundle.dart`).
- **Crash reports**, uploaded automatically on the next launch or connect (`native/lib/diagnostics/crash_reporter.dart`). They hold the error, stack trace, device model, OS and app version.
- **Update checks** in sideloaded builds: a request for the published version file. A downloaded update is installed only if its sha256 matches the manifest and its package name and signing certificate match the running app.

Details for each, and which builds include them, are in [developer.md](developer.md) and [docs/PRIVACY.md](docs/PRIVACY.md).

## The companion server

`server/index.js` serves the install page, the published builds and the update manifest, relays bug reports, and hosts the Claude Code approval bridge. It never sees SSH traffic.

- Static responses carry `Cache-Control: no-store` and a restrictive CSP (`script-src 'self'`, `frame-ancestors 'none'`).
- The feedback routes require the `X-MobiSSH-Key` header and are rate limited (`server/feedback-guard.js`).
- The approval hook (`hooks/mobissh-bridge.sh`) fails open: when the server is unreachable, or no client is listening, it answers with the configured default mode, which is `allow` unless `.approval-mode` says otherwise. Do not rely on it as a security control.
- Access control is the network layer: run it on a tailnet, not on the open internet.

## Threat model

In scope: protecting credentials at rest, host-key verification, transport integrity, and keeping session content off the developer's systems.

Out of scope: network-level attacks (delegated to Tailscale/WireGuard), compromised SSH servers, and a compromised or unlocked device.

## Audits

`scripts/security-audit-native.sh` runs the native audit. The reports in [`assessments/`](assessments/) (March 2026) reviewed the retired PWA and its WebSocket bridge; their findings do not apply to the native app.

## Reporting vulnerabilities

This is a personal project. If you find a security issue, please open a GitHub issue or contact the maintainer directly.
