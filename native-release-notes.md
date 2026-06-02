# MobiSSH native — release notes

Curated, USER-FACING notes rendered on the install page (native.html). Newest
section first; the generator renders the TOP section's bullets as "What to
verify". Each bullet: ONE short line, what changed — NOT how to test it. Keep
internal/test/CI/refactor work OUT. **Update this every release** (the gate
refuses to ship if the top section's commit is older than the build — see
gen-apk-install-page.sh staleness check).

## Build 2026-06-02g — terminal fills (real fix), inline connect, in-app feedback, app icon
- Terminal fills the screen on first connect — explicit resize after the font settles (tmux status bar should sit at the bottom, no mid-screen float). If it's still off, the new in-app feedback now carries an on-device size log so we can pinpoint it.
- Tap a profile to connect: inline "Connecting…" then inline error + Retry on the row — no modal popup.
- NEW: in-app feedback — a top-center button → one-tap screenshot + full comment, sent straight into the fix loop (no browser, no truncation).
- App now uses the MobiSSH icon instead of the default Flutter icon.

## Build 2026-06-02f — first-connect fill, connect errors, per-session files, keybar Enter
- Terminal fills the screen on first connect — no keyboard tap needed.
- Unreachable hosts now show a clear "Connection failed" dialog (Back / Retry) instead of hanging silently.
- Each session row has a file icon that opens that session's files.
- Keybar Enter shows a proper return icon (was an unreadable box) and sends Enter.

## Build 2026-06-02e — visual polish: profile list fills, slimmer chrome, slim menu
- Profile list now fills the screen — no more huge blank space below it.
- Session bar + keybar shrunk ~25%; Home and End now fit on the keybar, ESC is normal-width.
- Session menu slimmed to a compact icon row.

## Build 2026-06-02d — font size persists per profile
- Terminal font size now sticks per profile — set it once and it's remembered across restarts and reconnects.

## Build 2026-06-02c — terminal fills the screen + compose pills
- Terminal now fills the screen on first connect (no dead gap) and re-fits when the keyboard or keybar change.
- Copy, Paste, and Fix are now inline pills; the right-side buttons stay just close/clear/commit/submit.
- Fix rejoins a wrapped command/URL back into one clean, runnable line (matches the PWA).

## Build 2026-06-02 — compose bar fixes
- Enter or Commit now hides the compose box so the full terminal is visible again.
- The compose text area keeps its focus when you switch apps and come back.
- Drag handle moved to the top edge (wider text area) + Copy and Paste pills.

## Build 2026-06-01h — disconnect indicator, auth timeout, home reshape
- Disconnected terminal now shows a clear indicator; scroll gestures no longer dump stray characters while a session is down.
- A stuck SSH login now times out instead of hanging forever.
- Home is just your profiles + one-tap connect — Settings and Diagnostics moved to a bottom nav with their own views.

## Build 2026-06-01g — run-on-connect command + per-session font fixes
- Run-on-connect command now fires reliably, including on slow hosts (e.g. ra-server) where it was being dropped.
- Per-session font size now sticks and applies to the right terminal.

## Build 2026-06-01f — tmux scrollback works
- Drag up/down in tmux now scrolls back through history (xterm wheel-code bug fixed).
- Long-press selection menu removed (paste stays on the keybar).

## Build 2026-06-01e — full theme set + compose auto-focus
- 38 terminal themes (was 2) — assign a different one per session from the session menu.
- A profile's saved theme now applies automatically when you connect it.
- Profile editor: theme is a picker (all themes), not a text field.
- Compose bar grabs focus on open — straight into voice/swipe.

## Build 2026-06-01d — keyboard no longer covers the bottom bar (P0)
- Bottom session bar floats above the soft keyboard instead of being covered by it.
- Compose bar docks to a fixed top/bottom margin — no longer off-screen or hiding the session bar.
- Compose toggle on the session bar (right edge); swipe-type + voice land with correct spaces.
- Per-session font size + theme from the session menu.
- Keybar: one scrollable line, monochrome arrows, ^keys grouped at the end.

## Build 2026-06-01 — reliability sweep (verify on device)
- Profiles screen is now a clean chooser: TAP a saved profile to connect, tap the PENCIL to edit it, "New connection" to add one. The old inline host/port/Connect form is gone.
- Creating or editing a connection: the "Save & connect" / "Save" buttons stay ABOVE the keyboard — fill in a new key-auth host and confirm you can actually reach and tap them.
- Reconnect gives you a LIVE shell every time: connect, drop/disconnect, reconnect — the terminal should accept typing again (no frozen "connected but dead" screen).
- Opening the bottom session menu while typing should NOT drop the keyboard or make the screen jump.
- Long-press on the terminal opens Copy / Select all / Paste.
- Downloading a LARGE file or a PDF over SFTP should arrive intact (not corrupted) — try a multi-megabyte file.
- Re-importing your profiles applies the correct auth mode — a key profile shows as KEY (not password) after import.

## Build 2026-05-31 — earlier UX pass
- Tap-to-connect from a saved profile; pencil opens a full profile editor (title, host, port, user, auth, initial command, theme).
- Bundled JetBrains Mono terminal font; terminal theme cycling.
- Gesture pass: horizontal swipe on the session bar switches sessions.
