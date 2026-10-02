# MobiSSH

A mobile-first SSH and SFTP client for driving coding agents and servers from a phone. The app speaks SSH directly (dartssh2) with no relay and no proprietary protocol, so Claude Code, Codex, OpenCode or anything else runs in its normal shell on your host. Terminal rendering uses libghostty.

Android is the primary platform; Linux and macOS desktop builds exist.

## Features

### Terminal that understands its output

- **Link, path and command detection.** URLs, absolute and relative file paths, and shell command lines in the output get a soft colour wash under the text (the glyphs stay full contrast) and a chip in the gutter at the screen edge. Settings → Detection turns each type on or off.
- **Tap to act.** Tap a URL to copy it. Tap a path or `file://` link to open the file browser at that folder. Tap a command's gutter chip to copy the whole command. Long-press (with mouse mode on) or tap a chip for the full menu: Open, Copy, the `sftp://` form, and "Not a URL / Not a file" to stop detecting that exact text.
- **Verified paths.** A detected path turns a bolder shade once the app has checked over SFTP that it exists on the host. Short and relative paths stay hidden until they verify, so stray words don't light up.
- **Detection Lab.** Pick colours and intensity per pattern with live previews, edit the command lexicon, and add your own regex patterns with a sample line and a live compile check (Settings → Detection lab).
- **Highlight options.** The detection icon in the session menu opens a sheet: on/off, intensity (low, medium, high), gutter side (left or right), and whether the gutter overlays the last column or takes its own.
- **Browser per profile.** Choose which installed browser opens links, app-wide or per profile (work hosts can open in a work browser). If the chosen browser is gone, the link opens in the default and says which one was missing.
- **Copy whole lines from the gutter.** Long-press the gutter strip and drag to pick visible lines; they are copied on release.

### Built for touch and tmux

- **Swipe to scroll.** With tmux mouse mode on, a vertical swipe scrolls tmux's history; in a plain shell it scrolls the local scrollback. Scrolling moves by whole rows.
- **Swipe between tmux windows.** A horizontal swipe goes to the previous or next window, and tapping a window name in the status line selects it. These use tmux's default mouse bindings, so no prefix or custom keys are needed.
- **Keybar.** Esc, sticky Ctrl, Tab, arrows, Home, End, PgUp, PgDn, Paste, ^C, ^Z, ^B, ^D, and a Reset key that clears a stuck mouse mode locally.
- **Compose bar.** A floating text box where swipe typing, voice dictation and autocorrect work. Send a line or a multi-line paste, and recall earlier entries per session.
- **Multiple sessions.** Swipe the session bar to switch. Sessions survive the app going to the background (an Android foreground service keeps them alive) and reconnect on resume if they dropped.
- **Notifications.** A terminal bell, OSC 9 or OSC 777 from a background session raises a notification; tapping it opens that session and, for tmux, the window that rang. [INTEGRATION.md](INTEGRATION.md) shows how to make Claude Code, Codex, Gemini CLI or OpenCode ring when they need you.
- **tmux control mode (experimental).** An opt-in setting attaches with `tmux -CC` and switches windows with real tmux commands. Off by default; scrollback does not render in this mode yet.

### SFTP client with round-trip editing

- **Browse** any folder on the host, with sort by name, date, size or type (saved per profile), favourites, back history, and a per-profile start folder.
- **Create** a new folder or a new file (it never overwrites an existing name).
- **Download and share** files; downloads check the received size against the server's and fail loudly on a mismatch.
- **Upload** from the phone, resuming from where an interrupted upload stopped.
- **View** Markdown (rendered, with Mermaid diagrams and inline images), text and code, PDF, HTML, and images (PNG, JPEG, GIF), with pinch-zoom where it makes sense.
- **Edit Markdown and save it back** over SFTP, with the full phone keyboard (swipe and voice included). A failed save keeps your text and offers Retry; leaving with unsaved edits asks first.

### Profiles, keys and connections

- **Profiles** with host, port, user, password or key, an initial command to run after connecting, a start folder, a theme, a link browser and an optional jump host.
- **Paste an `~/.ssh/config` Host block** to fill a profile, including `ProxyJump`. Export your profiles as an ssh_config file (no secrets in it).
- **Jump hosts.** A profile can connect through another saved profile, like `ssh -J`, up to 3 hops, each with its own credentials and host-key check. Jumped sessions show a route icon that lists the hops.
- **SSH key library.** Paste a key once, name it, and attach it to any number of profiles. View and copy the public key.
- **Host keys.** First contact asks you to trust the fingerprint. A changed key refuses to connect and offers a Review screen with both fingerprints; the new key is never trusted in one tap.
- **Port forwarding.** Local forwards (`ssh -L`, bound to 127.0.0.1), optionally re-armed on every connect.
- **Encrypted backup.** Export everything (profiles, passwords, keys, host-key trust, settings) to one passphrase-encrypted file, and import it on another device.
- **`mobissh://` links.** Other apps can open a saved profile, attach a tmux session, or select a tmux window. The app asks before a link connects, unless you allowed that profile.
- **Themes and fonts.** 38 terminal palettes (per profile, or per session from the session menu) and 6 bundled monospace fonts with adjustable size.
- **Tablets.** In a large landscape window the session bar moves to the top and the keybar hides by default.

## Install

Download the APK from the [GitHub releases](https://github.com/flavordrake/mobissh/releases) page and install it (Android asks you to allow installing from your browser or file manager). Release builds are arm64. A macOS build is attached to some releases.

## Server setup for touch, mouse and scroll

MobiSSH needs nothing installed on the server beyond `sshd`. Touch scrolling and window swiping inside tmux use tmux's mouse support, which is off by default. Turn it on:

```
# ~/.tmux.conf
set -g mouse on
set -g history-limit 5000
set -g window-size latest
```

Reload a running tmux server with:

```
tmux source-file ~/.tmux.conf
```

What each line does:

- `mouse on` makes tmux accept the mouse reports the app sends (SGR 1006 encoding). A vertical swipe becomes a wheel event, so tmux enters copy mode and scrolls its history; a horizontal swipe on the status line switches windows. Without it, a swipe inside tmux sends arrow keys instead of scrolling, and long-press menus on detected links are not available (the gutter chips still work).
- `history-limit` sets how far back you can scroll in tmux.
- `window-size latest` sizes the session to the most recently active client. Without it, a laptop or a stale client attached to the same session can shrink the phone's view, and the status-line swipe can land in the pane instead.

Without tmux, everything except window swiping works: a vertical swipe scrolls the app's own scrollback, and detection, the gutter, the keybar, the compose bar and the file browser behave the same.

If a program exits and leaves mouse reporting on, taps print codes like `0;19;13M` at your prompt. Tap the Reset key on the keybar to clear it; it resets the app's input modes locally and sends nothing to the server.

## Usage

1. Tap **New connection** on the home screen, fill in the host and user, and choose a password or a key (or paste an ssh_config block on the SSH config tab).
2. Tap the profile to connect, and trust the host key on first contact.
3. Type directly into the terminal, or tap the compose button to write with swipe or voice and send.
4. Open the session menu from the session bar for files, port forwards, link-highlight options, theme and font size, and the other open sessions.
5. Use the Files icon in the session menu, or tap a detected path, to browse, view and edit files.

## Security and privacy

Credentials are stored with the platform's secure storage (Android Keystore, Apple Keychain, libsecret on Linux), never in plaintext. Sessions go straight from the device to your server. See [SECURITY.md](SECURITY.md) and [docs/PRIVACY.md](docs/PRIVACY.md).

## Development

Building, testing, the companion server, diagnostics and the features that are not part of a release build are in [developer.md](developer.md).

## License

MIT. See [LICENSE](LICENSE).
