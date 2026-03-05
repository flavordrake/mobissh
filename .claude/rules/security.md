# Security

- **Never store sensitive data (passwords, private keys, passphrases) in plaintext.** Use the encrypted vault (PasswordCredential + AES-GCM) or don't store at all.
- If the vault is unavailable, **block the feature**; do not fall back to plaintext storage with a warning.
- No secrets in code.
- PasswordCredential + AES-GCM vault is Chrome/Android only. iOS gets no credential persistence until WebAuthn (#14) is implemented.
- Keep `Cache-Control: no-store` on all static responses and service worker network-first. No stale cache.
