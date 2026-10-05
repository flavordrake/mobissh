# MobiSSH

An SSH and SFTP client for Android, built for driving coding agents and servers from your phone.

MobiSSH speaks SSH directly from the phone to your host (dartssh2, no relay, no proprietary protocol), so Claude Code, Codex, OpenCode or a plain shell run in their normal environment. The terminal renders through libghostty. It is built for use over Tailscale or any network where your host's `sshd` is reachable.

## Features

- **Links, paths and commands light up.** URLs, file paths and command lines in the output get a soft highlight and a chip in the gutter. Tap a URL to copy it, tap a path to open it in the file browser, tap a command's chip to copy the whole command.
- **SFTP browser with round-trip editing.** Browse the host, open a Markdown file, edit it with the full phone keyboard and save it back. Uploads resume; downloads are size-checked.
- **Viewers.** Rendered Markdown (with Mermaid), text and code, PDF, HTML and images, with pinch-zoom.
- **Swipe scrolls tmux.** With tmux mouse mode on, a vertical swipe scrolls tmux's history and a horizontal swipe changes window; no prefix keys.
- **Keybar and compose bar.** Esc, sticky Ctrl, Tab, arrows and the usual control keys in one row; a compose box where swipe typing and voice dictation work, with per-session history.
- **Multiple sessions** that survive the app going to the background and reconnect on resume. A bell or OSC 9 from a background session raises a notification ([INTEGRATION.md](INTEGRATION.md) shows how to make coding agents ring).
- **Host-key trust you can check.** First contact shows the SHA256 fingerprint; a changed key refuses to connect and shows both fingerprints for review.
- **Profiles, keys and jump hosts.** Paste an `~/.ssh/config` Host block (ProxyJump included), keep a named SSH key library, connect through up to 3 jump hosts, and set up local port forwards.
- **Encrypted backup.** Profiles, passwords, keys and host-key trust in one passphrase-encrypted file you can restore on a new phone.
- **Fonts and themes.** 7 bundled monospace fonts, including Iosevka and JetBrains Mono, and 38 terminal palettes.
- **Bug reports survive being offline.** A report that fails to send is kept on the phone, retried later, and can be shared as a file instead.

Every feature, with details: [docs/features.md](docs/features.md).

## Install

1. Download the `arm64-v8a` APK from the latest [GitHub release](https://github.com/flavordrake/mobissh/releases).
2. Open it on the phone. Android asks you to allow installs from your browser or file manager the first time.
3. Tap **New connection**, enter host, user and a password or key, connect, and trust the host key.

Android only for now; it is not on the Play Store. The in-app updater only works against the maintainer's install host, so an APK from GitHub is updated by installing the next release over it.

## Server setup for touch scrolling in tmux

Nothing is needed on the server beyond `sshd`. For swipe scrolling and window switching inside tmux, turn on its mouse support:

```
# ~/.tmux.conf
set -g mouse on
set -g history-limit 5000
set -g window-size latest
```

Reload with `tmux source-file ~/.tmux.conf`. What each line does, and what to do if taps start printing `0;19;13M`: [docs/features.md](docs/features.md#server-setup-details).

## Security and privacy

Credentials are stored in the platform's secure storage (Android Keystore), never in plaintext, and sessions go straight from the phone to your server. Nothing leaves the phone for the developer unless you send a bug report: [docs/PRIVACY.md](docs/PRIVACY.md), [SECURITY.md](SECURITY.md).

## Development

Building, testing, the companion server, diagnostics and what is not in a release build: [developer.md](developer.md).

## License

MIT. See [LICENSE](LICENSE).
