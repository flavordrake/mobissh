# MobiSSH native — release notes

Curated, USER-FACING notes rendered on the install page (native.html). Newest
section first; the generator renders the TOP section's bullets as "What to
verify". Each bullet: ONE short line, what changed — NOT how to test it. Keep
internal/test/CI/refactor work OUT. **Update this every release** (the gate
refuses to ship if the top section's commit is older than the build — see
gen-apk-install-page.sh staleness check).

## v0.1.9 (2026-06-04) — connect-hang fix + hold-to-repeat keys + Ghostty default + tap-to-copy URLs
- **Connect can no longer silently hang** — if the background service outlived the app, tapping a profile used to do nothing; now the app re-syncs with the live service (and surfaces an error instead of hanging). Fixes "tap connect, no response" (#731).
- **Hold an arrow / nav key to auto-repeat** — press-and-hold ← ↑ ↓ → (and Home/End/PgUp/PgDn) repeats with a tiny haptic tick; a quick tap still sends one (#732).
- **Ghostty (flterm) is now the default terminal engine** — xterm is still selectable in **Settings → Terminal engine**.
- **Tap a URL to copy it** — URLs in terminal output are highlighted; single-tap copies to the clipboard. Tapping elsewhere is unchanged.
- **Keybar Ctrl now works with the soft keyboard** — arm **Ctrl**, then press a letter on the keyboard (e.g. **R**) → Ctrl+R reaches the shell; Ctrl auto-clears.

## v0.1.8 (2026-06-03) — Ghostty terminal, hardened
- **Ghostty (flterm) is the recommended engine** — native touch drag-select + copy, precise tmux selection, faster scrolling. Turn it on in **Settings → Terminal engine** (it becomes the default in the next build).
- Ghostty terminal:
  - **Long-press to select** (the selection persists — tap **Copy** → system clipboard); **single tap dismisses** it; Copy / Select-all appear only while selecting.
  - **Tap raises the keyboard**; tapping a tmux status-bar window selects it.
  - **First connect fills + scrolls** without a keyboard toggle; **app-switch and device-unlock show the latest immediately** (no tap).
  - **Swipe up/down scrolls; swipe right/left switches tmux windows** (reliably, at any size).
  - Per-session **theme** (38), **font** (now incl. RobotoMono / UbuntuMono / Cousine), and size — all recolor/retype the live terminal.
- **Keybar:** sticky **Ctrl** modifier (next to Esc) → next key is Ctrl+<key>; larger, higher-contrast labels; tighter single-character keys.
- **Reach Profiles / Settings from a live session** — session menu → "Profiles & settings" opens over the session (it keeps streaming); back returns. Session-menu font is −/+ and theme/font are pickers.

## v0.1.7 (2026-06-03) — Ghostty: swipe scrolls in tmux (no selection capture)
- Ghostty: in tmux / mouse-mode sessions, a **swipe now scrolls the scrollback** (sends wheel events) instead of triggering tmux's selection — the swipe was previously forwarded as a mouse-drag. tmux's precise native selection still works on a deliberate drag (select-mode); plain shells were already fine.

## v0.1.6 (2026-06-03) — Ghostty: swipe scrolls, selection is deliberate
- Ghostty: a swipe now **scrolls the scrollback cleanly** — no more accidental selection block (long-press was grabbing the swipe). Tap the new **select-mode** button (touch-app icon) to deliberately long-press-drag a selection, then Copy; tap it off to return to scroll.
- Known flterm limits (a fork would be needed): in select mode a long-press-drag still auto-scrolls at the screen edge, and there are no draggable selection-endpoint handles yet.

## v0.1.5 (2026-06-02) — Ghostty polish (font + gestures)
- Ghostty now uses your selected per-session font + size (JetBrains Mono default — readable, no more thin default).
- Vertical drag scrolls the scrollback (it no longer starts a selection); long-press to select, drag to extend, plus Select-All.
- (Draggable selection-endpoint handles aren't in flterm yet — long-press + drag-extend for now.)

## v0.1.4 (2026-06-02) — experimental Ghostty terminal engine (opt-in)
- Settings → Terminal engine: switch between xterm (default) and **Ghostty** (experimental), restart to apply. Ghostty has native touch drag-select + copy — long-press and drag to select, then Copy.
- xterm stays the default; flip to Ghostty to try it on a real session.

## v0.1.3 (2026-06-02) — terminal font selector
- Pick your terminal font per session — JetBrains Mono, Fira Code, or Cascadia Code — from the font control in the session menu. Remembered per profile, like theme and size.

## v0.1.2 (2026-06-02) — copy & navigate URLs (Slice 1)
- Long-press a URL in the terminal → a Copy / Open menu (Open launches your browser). The matched URL is highlighted, including when it wraps across lines.
- Works on the live terminal without disturbing scroll or mouse-mode apps.
- (Foundation for arbitrary smart-pattern detection — configurable patterns + OSC 8 hyperlinks are the next slices.)

## v0.1.1 (2026-06-02) — session/keybar/toast polish
- Keybar visibility is now per-session — hide it on one session without affecting the others.
- Toasts/confirmations now appear at the TOP of the screen so they never cover the keybar or session bar.
- Profiles: "Import from PWA" is now just "Import", and New + Import share one button row.
- Diagnostics "Share feedback" is now labeled as the offline backup (the top Feedback button is the primary path).

## v0.1.0 (2026-06-02) — first tagged native release
First versioned cut of the native app (replaces the date+letter daily-build labels). Everything below this line shipped under the rapid date-letter builds; this tags it as v0.1.0. Daily iterations now use v0.1.x.
- Daily-driver baseline: multi-session SSH that survives backgrounding + auto-reconnects; profiles with keys/passwords, per-profile theme/font/color; SFTP file browser; 38 terminal themes.
- Terminal fills the screen on first connect (the PTY re-syncs on shellReady); centered session title + per-session color swatch; per-session theme & font.
- In-app feedback: one-tap screenshot (captured at the moment of tap) + full comment + on-device diagnostic log, straight into the fix loop.

## Build 2026-06-02l — centered session title + per-session color swatch
- The session title is now centered in the bottom bar instead of colliding with the menu.
- Each session shows a small color swatch matching its profile color (or its theme accent) — the same color identifies the same profile, like the PWA. Set a profile's color in the editor to tag it.

## Build 2026-06-02k — first-connect fill, fixed at the real cause
- The first-connect re-sync now fires the moment the remote shell exists (on the shellReady signal), so it lands as a real resize instead of being dropped before the shell was ready. tmux should fill on the very first connect — status bar at the bottom.
- (Two bugs from your 'j' log: the re-sync fired ~10ms too early and got dropped, and the retry-burst was never actually running on device. Both fixed.)

## Build 2026-06-02j — first-connect terminal fill (real fix, from your log)
- First connect after launch now fills the screen — the remote (tmux) gets the correct size even when the local terminal was already right. Your connect log pinned it: the PTY had attached at the default ~80×24 and was never re-synced; now it is, on connect. (tmux status bar should sit at the BOTTOM.)
- Feedback screenshot now captures at the moment of tap — interacting with the form can no longer re-lay-out the screen before the shot.
- If first connect is still off, the connect log now shows a `RESYNC` line with the exact sizes.

## Build 2026-06-02i — feedback now carries the on-device diagnostic log
- In-app feedback now attaches the connect/CTRACE log (measured terminal size, computed rows/cols) to your report — so a bad first-connect screenshot finally comes with the numbers to fix it, no more bouncing builds. (Scrubbed of anything secret.)
- Tap Feedback on a broken first-connect screen → the report carries exactly what the terminal measured.

## Build 2026-06-02h — in-app feedback actually opens now
- Tapping Feedback used to just blink — now it opens the comment sheet and shows a "Feedback sent — thanks!" confirmation. (It was mounted above the navigator, so the sheet couldn't open.)
- Use it on a broken first-connect screen: it bundles the on-device size log so the terminal-fill bug can finally be pinpointed.

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
