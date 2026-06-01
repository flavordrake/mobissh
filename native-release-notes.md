# MobiSSH native — release notes

Curated, USER-FACING notes rendered on the install page (native.html). Newest
section first. The install-page generator renders the TOP section's bullets as
"What to verify" — so write each bullet as something the owner can tap-test on
the device, not as a commit subject. Keep internal/test/CI/refactor work OUT.

## Build 2026-06-01b — compose bar (swipe / voice) + per-session look (verify on device)
- NEW: Compose bar for swipe-typing + voice. Open the session menu → toggle "Compose bar (swipe / voice)". An editable docks above the keybar — swipe-type a phrase (SPACES should appear correctly now) or tap the keyboard mic to dictate, then ✓ sends the text (no Enter) / ⏎ sends text + Enter. This is the workaround for the terminal itself not accepting swipe/voice. THIS IS THE THING TO TEST.
- Per-session font size + theme: session menu has a font −/＋ stepper and theme cycle that change ONLY the active session — set prod small/one color, dev large/another, to tell sessions apart.
- Keybar is now one scrollable line of touch-friendly buttons; paste icon is monochrome (was an emoji).
- Session menu floats above the bottom bar — tapping the session-bar trigger again now dismisses it (no longer lands on Files).

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
