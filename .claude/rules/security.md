# Security

- **Never store sensitive data (passwords, private keys, passphrases) in plaintext.** Secrets go through `native/lib/storage/secrets_store.dart` (`flutter_secure_storage`: Android Keystore-backed encrypted prefs, Apple Keychain) or are not stored at all.
- If secure storage is unavailable, **block the feature**; do not fall back to plaintext storage with a warning.
- Encrypted backup (`native/lib/storage/backup.dart`) is AES-256-GCM with an Argon2id key from a user passphrase. Never write an unencrypted export of secrets.
- No secrets in code.
- There is no biometric gate. The unused `local_auth` dependency was removed in #1261. Do not document one.
- Keep `Cache-Control: no-store` on all static responses from `server/index.js`. No stale cache.
