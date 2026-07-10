# MobiSSH native — release notes

Curated, USER-FACING notes rendered on the install page (native.html). Newest
section first; the generator renders the TOP section's bullets as "What to
verify". Each bullet: ONE short line, what changed — NOT how to test it. Keep
internal/test/CI/refactor work OUT. **Update this every release** (the gate
refuses to ship if the top section's commit is older than the build — see
gen-apk-install-page.sh staleness check).

## v0.1.10+132 (2026-07-10) — define your own detection patterns
- **Add your own patterns in the Detection lab**: name + regex with live validation and a sample-line preview highlighting what matches. Your patterns get the full treatment — bubbles, gutter chips, tap-copy, colors/intensity, "Not a match" exceptions — live in open sessions, no reconnect. Deleting a pattern tells you it also clears its saved exceptions. (#1031)

## v0.1.10+131 (2026-07-10) — pick any profile color + the Detection Lab
- **Full color picker for profile colors** — the profile editor's swatch now opens a real HSV picker with hex entry; presets stay one-tap. (#1030)
- **Detection Lab** (Settings → Detection → Detection lab): per-pattern control with live previews — recolor any pattern's highlight, tune wash intensity (detected and verified states where they exist), edit the command-word list, and see the real bubble/chip rendering update as you drag. Per-pattern and lab-wide resets included. (#1031)

## v0.1.10+130 (2026-07-09) — bare ~ is not a path
- **A lone `~` no longer gets a path bubble** — only `~/...` anchors. (#1024)

## v0.1.10+129 (2026-07-08) — disconnect/reconnect state machine hardened
- **Disconnecting a session is now clean**: no more phantom reconnect attempt (and debug assert) right after you close a session, and a session you closed can't resurrect itself if a connect was mid-flight. (#986)
- **Keepalive stop is race-free**: a stale scheduled stop can no longer kill the background service just as another session connects — completes the #1018 fix. (#1021)

## v0.1.10+128 (2026-07-08) — keepalive survives connection blips
- **The background connection service no longer dies during a reconnect** — a dropped session now holds the service through the whole soft-drop → reconnect cycle instead of releasing it for a moment (which could kill all sessions mid-recovery). Closing a session yourself still shuts it down. (#1018)

## v0.1.10+127 (2026-07-08) — no more mouse-code garbage after a reconnect
- **Reconnected sessions no longer spill `[<65;…M` mouse codes into the prompt** — the app resets its mouse/scroll mode assumptions when a session revives; a live TUI (tmux with mouse on) re-enables them automatically. From your connection-lost report — the reconnect itself was already succeeding. (#1014)

## v0.1.10+126 (2026-07-08) — copy a whole command line with one tap
- **Command lines get their own gutter chip** (terminal glyph): tap copies the entire command — prompt stripped, wraps joined, paste-exact — while URLs/paths inside it keep their own bubbles and taps. Built from your real terminal captures; strict about not marking prose. Toggle under Settings → Command lines. (#998)
- "Not a command" available in the chip's sheet, joining the detection exceptions. (#995)

## v0.1.10+125 (2026-07-08) — teach detection what's NOT a link or file
- **"Not a URL" / "Not a file" in the long-press menu** — marks that text as a detection exception: its bubble and chip vanish now and stay gone across sessions. Review and remove exceptions under Settings → Detection exceptions. (#995)
- Groundwork for whole-command detection (copy a full wrapped command line) landed under the hood. (#998)

## v0.1.10+124 (2026-07-08) — file:// links act like paths; no more glued-on URL tails
- **file:// links are treated as remote paths**: tap opens the file browser there; the menu offers the bare path (for command lines) and a full sftp:// URL. (#994)
- **Short URLs no longer swallow the next line** — a line that never reached the wrap edge can't be joined anymore (the `…/track9931` class). (#1007)

## v0.1.10+123 (2026-07-08) — soft bubble wash + gutter chips ride their lines
- **Bubbles are now a soft translucent wash** (no hard border) — same green family as the gutter chips, pale for detected, stronger for verified paths, with more breathing room under the text. (#1000)
- **Gutter chips track their line while you scroll** instead of staying pinned. (#993)

## v0.1.10+122 (2026-07-08) — tap a path to browse there, wrapped URLs join fully, fake paths verify away
- **Tapping a detected path opens the file browser there** (file → its folder); copy moved to long-press. URLs still tap-copy. (#999)
- **Paths are verified against the host**: real paths get a bolder mark once confirmed to exist; short matches like `/config` or `/rc` (usually command suggestions, not files) stay hidden unless they actually exist. (#990)
- **Wrapped URLs in TUI output (Claude Code style hanging indent) now detect and copy in full** — your `agent-hub` curl example is the regression test. (#996)
- Bug-report uploads can now run on a dedicated service container (server-side change, no app impact). (#997)

## v0.1.10+121 (2026-07-08) — URL/path bubbles are back, and the gutter marks feel like buttons
- **Tap a URL or path to copy it — the bubble shows exactly what you'll get.** Detected URLs and file paths get a capsule bubble again; it hugs the real content across wrapped lines (rounded ends only at the true start/end, no margin whitespace), so the bubble IS the preview of the copy. Single tap copies; Open stays on long-press and the gutter mark. (#988)
- **Gutter marks are bigger, high-contrast chips** — solid tappable buttons at the right edge (link vs folder glyphs), with pressed feedback and a comfortable touch target. (#989)

## v0.1.10+120 (2026-07-08) — the "screen stops updating" bug is fixed at the root
- **The screen keeps painting.** The years-long "paint not happening" freeze (busy output + URL detection on) is root-caused and fixed — the screen no longer sticks on a stale frame while output streams. Reproduced from your actual bug-report trace, pinned by tests.
- **Control mode: window switching works right after connect.** Tapping the tmux status bar switches windows deterministically on a freshly-attached session (no longer dependent on a lucky resize). (#906)
- **Bug reports now self-diagnose paint and control mode** — every report carries paint counters (bytes → notifies → paints) and a control-mode trace (attach, handshake, window list, each tap's resolution).

## v0.1.10+95 (2026-06-30) — gutter selection no longer fights the terminal's own selection
- **Long-pressing the gutter selects ONLY the gutter lines** — the terminal's native text selection stays out of its way (no more two overlapping selections) — and dragging up/down adjusts the range. Copy still reads those visible lines verbatim. (#962)

## v0.1.10+94 (2026-06-30) — copy reads the visible screen verbatim; scrolling no longer breaks
- **Selecting is now LONG-PRESS-then-drag in the right gutter** — a normal swipe always scrolls (no more eaten scroll-backs), and a hold-then-drag selects whole lines with a full-width highlight. (#962)
- **Copy now reads the visible screen verbatim** — exactly the lines you dragged over, straight off what's on screen, with none of the scroll-offset guessing that grabbed the wrong text. (#962)

## v0.1.10+93 (2026-06-30) — gutter selection is visible again, and copy matches it
- **Dragging the gutter highlights the selected lines across the whole screen again** (no more guessing from the gutter), and **Copy now copies exactly what's highlighted** — drag until the right lines light up, lift to copy them. (#962)

## v0.1.10+92 (2026-06-30) — gutter copy no longer repaints the screen (+ copy diagnostics)
- **Selecting in the gutter no longer repaints the terminal text** — the only feedback is a band in the gutter strip, so the screen-repaint glitches during selection are gone. (#962)
- **Copy is being diagnosed.** The copy-grabs-wrong-text bug comes down to which scroll position the copy reads from; this build records all the candidates when you copy. If a copy still grabs the wrong text, tap Feedback right after — the report now captures exactly what happened so the next build fixes it for good. (#962)

## v0.1.10+91 (2026-06-30) — gutter selection highlights the whole line + copies the right text
- **Dragging the gutter now highlights the whole line across the screen** as your finger moves, so you can see exactly what you're selecting (not just a mark in the gutter). (#962)
- **It copies what you selected.** Copy now extracts the highlighted lines directly (the same proven path as the old selection), fixing the bug where it grabbed unrelated text from elsewhere. (#962)

## v0.1.10+90 (2026-06-30) — drag the gutter to select & copy whole lines
- **Select and copy whole lines by dragging the right edge.** Drag down (or up) the right-edge gutter to highlight whole lines; lift your finger and they're copied — a "Copied N lines" toast confirms. Line-granularity, so there's no fiddly per-character precision to fight, and copy can't grab the wrong region. (#962)
- **Detection marks still sit on top** — tap a link/path mark to open or copy it; drag elsewhere in the gutter to select lines. (The old long-press text selection still works for now.) (#955)

## v0.1.10+89 (2026-06-30) — Copy now copies what you selected
- **Copy puts the text you highlighted on the clipboard** — not a different region. In an active session, after selecting something while scrolled up, Copy was grabbing later output ("the wrong view"); it now honors exactly what you selected. (Interim fix; a line-select gutter is coming next.) (#962)

## v0.1.10+105 (2026-07-02) — The active session stands out in the switch menu
- **You can see which session you're in at a glance.** In the session switch menu, the current session now has a tinted highlight and a left accent stripe (on top of the bold name + highlighted terminal icon), instead of only a subtle bold. The highlight follows the active session as you switch.

## v0.1.10+104 (2026-07-02) — Copied URLs & commands join across wraps
- **Wrapped lines copy as one line.** When you gutter-copy a URL or command that wrapped at the edge — including in tmux and TUIs like Claude Code, where there's no wrap marker — it now pastes back as a single line instead of breaking at the margin. Box-drawing art stays as separate lines, and normal short lines keep their breaks.

## v0.1.10+103 (2026-07-02) — Review before you send a bug report
- **You now confirm what a bug report contains before it uploads.** Tapping Feedback opens a **Review & Send** sheet: preview the screenshot (or scrub through every frame of a recording), and toggle off the **screen images** and/or the **diagnostic traces** if they show something private. Nothing is sent until you tap **Send**; Cancel discards it. "View diagnostic text" shows the exact (secret-scrubbed) logs. This makes the privacy policy's "you review what's sent" literally true.

## v0.1.10+102 (2026-07-02) — Settings cleanup (Play Store prep)
- **Settings reads cleaner.** The terminal-engine picker is gone — Ghostty is the engine (it's what powers link/path marks, gutter copy, and everything else; the old xterm option quietly disabled all of that). Developer diagnostics (crash share / upload / connection audit) moved into a collapsed **Advanced** section. Everyday settings — keep-alive, battery, font size, link/path detection, tmux control mode — stay front and center.

## v0.1.10+101 (2026-07-01) — copied wrapped lines come out as ONE line
- **A long command or URL that the terminal wrapped across rows now copies as a single line.** The terminal itself knows which rows are soft-wrapped (vs real line breaks), so the gutter copy joins them back — no heuristics, no lost characters. TUI layout breaks (bullets, margins) keep their line breaks. (#962)

## v0.1.10+100 (2026-07-01) — link/path marks now appear inside tmux (#958 fixed)
- **The right-edge link/path marks finally show up in tmux sessions.** A coordinate mix-up meant detection worked but the marks (and taps on them) resolved off-screen whenever the session had any history — i.e. always, on a real device. Now a URL or file path on a tmux screen gets its gutter mark; tap it to copy/open. (#958)
- Behind the scenes: a new always-on end-to-end emulator test drives the full connect → tmux → TUI → scroll → copy chain on every terminal change, so this flow can't silently break again.

## v0.1.10+96 (2026-07-01) — copy: gutter is the only copy path (isolating the clipboard bug)
- **To copy, drag the right-edge gutter** to select whole lines, then release. Long-press text-selection and the floating Copy/Select-all buttons are **temporarily disabled** so only one thing writes the clipboard while we chase why copies weren't reaching Gboard on Pixel. If you copy and paste elsewhere and it still doesn't appear, **send a bug report** — this build records exactly what the system clipboard held (device/OS, focus, read-back) so we can pin it down. (#962)

## v0.1.10+88 (2026-06-29) — link/path detection toggle in the session menu
- **Turn the link/path gutter on or off from the session menu.** A new link toggle sits in the session menu's control row — tap it to switch the right-edge detection marks on/off (it's a quick way to verify the feature and force a fresh scan of the screen). Detection stays on by default. (#955)

## v0.1.10+87 (2026-06-29) — profile drag-reorder works on device
- **Dragging a profile's handle now reorders it.** Press the drag handle (top-right of a saved-profile card) and drag — no long hold needed. Tapping the same handle still opens the "Move to top / Move to bottom" menu. (#481)

## v0.1.10+86 (2026-06-29) — downloads now go to your Downloads folder
- **Downloaded files land in your real Downloads folder** — the one your file manager and browser show — instead of an app-private spot you couldn't find. The "Downloaded …" confirmation now shows the actual location (→ Downloads/<name>). (#559)

## v0.1.10+85 (2026-06-29) — reorder profiles + detected URLs/paths in a side gutter
- **Reorder your saved profiles.** Each profile card has a drag handle (top-right) — hold to drag it into order, or tap it for "Move to top / Move to bottom." Order is remembered. (#481)
- **URLs and file paths now show as marks in a right-side gutter** instead of inline highlights. A small mark appears next to any line with a detected link or path (a multi-line URL gets one mark); tap it to copy/open — or, if a line has several, pick from a list. This replaces the old inline highlighting that drifted/lagged during scroll. (#955)

## v0.1.10+84 (2026-06-29) — fix the crash on disconnect (release builds)
- **Disconnecting a session no longer crashes the app.** A release-build optimization was stripping data the notification system needs, so cancelling the keep-alive notification on disconnect threw. Added the proper keep-rules. (#915)

## v0.1.10+83 (2026-06-29) — much smaller, faster-downloading APK
- **The app download is ~3× smaller** (arm64-only build, ~30 MB vs ~91 MB) — faster to download and install. The build notification now opens the download in your browser, and the server reports the file size so you get a real progress bar + resumable downloads. (No app behavior change.)

## v0.1.10+82 (2026-06-29) — Diagnostics declutter (connect-log block removed)
- **Removed the raw connect-log viewer from Diagnostics.** That granular trace is still captured automatically with every Feedback submission, so nothing's lost — it just removes the debug noise from the settings page. (#897-adj)

## v0.1.10+81 (2026-06-29) — settings reorg + file-explorer sort/details
- **Settings is one clean page now.** Every setting is a top-level control (no more single big expander), grouped under light headings, with Diagnostics folded in as a section at the bottom and a new **Reset settings** action. (#897)
- **File explorer shows modification time** alongside size in each row, and a **sort menu** (⇅ in the top bar): sort by name, modified, size, or type, ascending or descending (per-profile, folders stay first). (#951)
- **Long-press a file or folder** for a menu: copy full path, copy name, show details, download, add to favorites. (#952)

## v0.1.10+80 (2026-06-29) — smaller, less-intrusive Feedback affordance
- **The Feedback control is now a small icon** tucked up against the top edge instead of a wider pill — it occludes much less of the terminal/text below. Tap it to send feedback, long-press to record a repro (unchanged). (#897-adj)

## v0.1.10+79 (2026-06-29) — upload files over SFTP (large files, resumable)
- **Upload a file to the server.** The file browser has an upload button (top bar) — pick a local file and it uploads into the folder you're viewing, with a progress bar. (#960)
- **Built for big files.** The upload streams in chunks (it never loads the whole file into memory) and writes to a temporary `.part` first, then swaps it into place when complete — so an interrupted upload never leaves a corrupt file.
- **Resumes interrupted uploads.** If an upload is cut off (e.g. the connection drops), uploading the same file again continues from where it left off instead of starting over.

## v0.1.10+78 (2026-06-29) — favorites star on each session in the menu
- **Open a session's favorites straight from the session menu.** Any session whose profile has marked favorites now shows a ★ on its row in the session menu; tap it to see that profile's favorites and jump straight to one (it opens the file browser there). Sessions without favorites don't show the star. (#950)

## v0.1.10+77 (2026-06-28) — full-screen diagrams now center + zoom crisply
- **Tapped mermaid diagrams open centered and zoom sharply.** The full-screen diagram now centers in the view (no more pinned to the top with empty space below) and pinch-zoom/pan is handled by the diagram itself, so it stays crisp and pans smoothly instead of feeling sluggish. (#949)
- **Tapped images open centered and fit the screen**, and stay sharp when you zoom in. (#949)

## v0.1.10+76 (2026-06-28) — tap any markdown image or diagram to fill the screen + zoom
- **Tap an image or diagram in a markdown preview to open it full-screen, then pinch-zoom and pan.** Inline images and mermaid diagrams now show inline at a readable size with a small expand badge; tap to blow them up full-screen where pinch/pan/zoom work, tap the ✕ to return. The flowed text still scrolls and selects as before. (#946)
- **One-tap "build ready" notification.** When a new build is published you get an ntfy push titled with the version and a Download button — tap it to grab the APK. (ntfy)

## v0.1.10+75 (2026-06-28) — file favorites + markdown mermaid diagrams
- **Favorite paths in the file browser.** Tap the star to favorite the current directory (per profile, saved across restarts). Long-press the star — or any file/folder — for the favorites menu: tap a favorite to jump there, long-press one to remove, or clear all. (#632)
- **Markdown previews now render mermaid diagrams.** A ` ```mermaid ` block in a .md file shows as the actual flowchart/diagram (rendered offline), not raw code — pinch-zoom and pan the diagram; the raw/source toggle still shows the text. (#942)

## v0.1.10+73 (2026-06-26) — tapping the tmux status bar switches windows again (keyboard-aware sizing)
- **Switching tmux windows works with the keyboard up.** The real cause of "tap the tmux tabs, nothing switches, only the cursor moves": when the soft keyboard was up, the terminal still told tmux it had the full (taller) height, so tmux drew its status bar OFF-SCREEN below the keyboard — your tap on the visible bottom landed in the middle of the pane (a cursor move, not a window switch). The grid now tracks the keyboard-reduced visible height, so the status bar stays at the visible bottom and the tap switches windows. This was a sizing bug, not a repaint bug (the earlier paint fixes were chasing the wrong thing). (#922) — verify: raise the keyboard, tap a tmux window in the status bar, it switches.

## v0.1.10+72 (2026-06-25) — attention no longer buzzes while you're on the session; repaint diagnostics
- **No more attention buzz for the session you're already viewing.** When a session disconnected, the app lost track of which host you were on (it went null), so a bell from that same host wasn't suppressed and notified you anyway. The active host is now always known from the session even while disconnected, so a bell for the session you're looking at stays silent. (#936)
- **Repaint diagnostics for the tmux window-switch issue.** The "switching tmux windows leaves the old window on screen" case (detect-URLs ON) doesn't reproduce in the test harness — it's a real-device timing thing. This build instruments the repaint path so a Feedback capture taken right after a stale switch pinpoints the cause. No behavior change; the fix follows the capture. (Workaround until then: detect-URLs OFF.) (#922)

## v0.1.10+71 (2026-06-24) — tmux window switch repaints (structural end of the repaint saga)
- **Switching tmux windows shows the new window now**, with URL/path detection on. The whole repaint saga's root: detection drives an extra screen-refresh per change, so the renderer's damage got consumed by that refresh before the painting pass read it — leaving the old window's content on screen. The frame builder now carries damage forward until a pass that actually paints re-reads the full screen, so an extra refresh can no longer strand the display. Replaces the per-case guards (#900/#921/#931) with one structural fix. (#922) — please verify: switch tmux windows a few times with detection on.

## v0.1.10+70 (2026-06-23) — repaint on resume/typing fixed, copy reaches other apps, version shown in Settings
- **The terminal repaints again when you switch back to the app and as you type.** With URL/path detection on, returning from another app or typing could leave the screen frozen on stale content while new output was actually arriving. Resume now forces a full re-read (not just a repaint nudge), and detection stays armed across resume/tab-switch so it can't silently stop refreshing. (#931)
- **Copied URLs/paths actually reach other apps now.** A copy could report success and show a correct preview yet not be pasteable elsewhere. Removed a post-copy clipboard self-read that disturbed Android's clipboard handoff, and marked the clip non-sensitive so the system surfaces it normally. (#924) — please verify by pasting into another app.
- **Settings now shows your running build.** A tappable version line (e.g. `[0.1.10+70 …]`, tap to copy) so you can confirm exactly which build is installed without uploading a report.

## v0.1.10+69 (2026-06-23) — wrapped URL copy stops truncating intermittently
- **Tapping a wrapped URL reliably copies the whole link.** A long URL that wrapped in the conversation/output sometimes copied only its first line (the same link would copy fully on one tap, truncated on another). Cause: a wrapped line's left indent is painted as either cleared cells or literal spaces depending on the repaint, and the wrap-merge only joined the cleared-cell case. It now treats a blank-looking indent the same either way, so the full URL always stitches together. (#928) (Note: a separate, transient "highlight sits a couple rows off the URL while scrolling" is tracked in #930.)

## v0.1.10+68 (2026-06-22) — diagnostics for stray attention notifications
- **Instrumented the attention-notification gate.** Chasing the "I get attention alerts while MobiSSH is the active app" report: each post/suppress now records its decision inputs (foreground, active session/host, signalling host) and the active-session hand-off is logged on both the UI and background sides, so a Feedback capture at a stray alert pinpoints the cause. No behavior change yet — the fix follows once a capture confirms it. (attention telemetry)

## v0.1.10+67 (2026-06-22) — copies the WHOLE wrapped URL, not just the first line
- **Tapping a wrapped URL now copies the entire link.** A long URL printed as output (e.g. inside the Claude TUI) wraps across several indented lines; tap-to-copy was grabbing only the first visible row, so you got a truncated link (and an empty Android copy-preview). The wrap-merge is now indent-aware and stitches the indented continuation rows back into one URL, so copy/open get the full link. (#925)

## v0.1.10+66 (2026-06-22) — fixes the terminal freezing when URL/path detection is on
- **Detect-URLs no longer stalls the screen.** With link/path highlighting on, the terminal could stop updating (output and window switches didn't repaint) — the actual root of the long repaint saga, independent of tmux. Detection added an extra redraw notify that consumed the screen's damage before it painted; the primary screen now re-reads the full visible grid whenever detection is active, so it stays current. Highlighting on costs nothing extra when off. (#921)

## v0.1.10+65 (2026-06-18) — terminal self-heals its repaint on every tap/keypress
- **The display refreshes itself whenever you interact.** The "screen looks stale until I tap Diagnostics" problem: now every keypress, tap, swipe, paste, and window switch forces the same full repaint that tapping Diagnostics did — so the terminal stays current as you use it, and streaming output settles to a clean frame on its own. Idle screens still cost nothing. This is on by default (no toggle needed). (#918)
- **Control-mode window switching repaints reliably.** With the experimental tmux control mode on, switching windows now redraws every time (a +64 issue where same-size switches could show a blank/stale grid). Still off by default. (#916)

## v0.1.10+64 (2026-06-18) — experimental: tmux control mode (authoritative window switching)
- **New Settings toggle: "tmux control mode (experimental)" (off by default).** When on, MobiSSH drives tmux via its control protocol (`tmux -CC`) instead of reading the screen — so window switches, sizing, and the active window come straight from tmux. This makes window-switch gestures land on the right window every time and keeps the terminal size in lockstep with tmux (no more stale repaint / wrong-row taps). Requires tmux on the host; reconnect the session after toggling. Leave it off to keep the current behavior. (#906)

## v0.1.10+63 (2026-06-18) — fixes the terminal not repainting during keyboard/window-switch churn (root cause)
- **The terminal repaints reliably while switching tmux windows and toggling the keyboard.** Root cause of the whole repaint saga: the app fired a PTY resize on every keyboard-animation frame (and a spurious one around each window switch), constantly re-gridding the terminal and racing the redraw. Resizes are now coalesced to the final settled size, so a window switch shows the right window. (#903)

## v0.1.10+62 (2026-06-18) — fixes tmux window-switch repainting only every other time
- **Switching tmux windows reliably repaints now.** +61 still updated the screen only on alternate switches (swipe once works, next doesn't); the renderer was depending on one-shot row "damage" that an earlier paint had already consumed. On an alternate-screen redraw it now re-reads the full visible grid, so every window switch shows the right window. (#900)

## v0.1.10+61 (2026-06-17) — fixes stale display after switching tmux windows
- **Switching tmux windows now repaints the screen.** Tapping the status bar to switch windows could leave the old window's text on screen with only the cursor moving (intermittent) — a redraw arriving mid-layout was being dropped. The terminal now always repaints on a screen update. (#898)

## v0.1.10+60 (2026-06-17) — profile default directory + toggleable detection + config-file viewing
- **Profiles can set a default directory.** A new optional "Default directory" field opens the file browser straight to e.g. `/files` on a VPS/seedbox instead of the SSH home. (#891)
- **Link & path detection is now a setting.** Settings has a Detection group — turn URL and file-path highlighting on/off independently (defaults on). (#888 Part A)
- **Extensionless config files open as text.** A bare `config`, `~/.ssh/config`, `Dockerfile`, or dotfile now opens in the file viewer instead of being unviewable; binary files show a "download instead" notice rather than garbled text. (#893)

## v0.1.10+59 (2026-06-17) — fixes terminal text rendering as blank
- **Terminal text no longer goes invisible.** Freshly-printed output (especially lines with a detected path/URL) could render as just a highlight with no text until something forced a repaint (e.g. opening Diagnostics). The glyph layer now always repaints with the decoration. (#887)

## v0.1.10+58 (2026-06-11) — notifications can't strand you anymore
- **Tapping a notification for a disconnected server reconnects it.** If the app was killed or the session closed, the tap now reconnects that server's profile and lands you in it — no more being dumped on the connection list while the notification dangles. If no saved profile/credentials can reconnect it, the stale notification is cancelled instead. (#885)
- **Attention notifications are cleared when their session ends.** A "needs attention" alert no longer outlives the session it points at. (#885)

## v0.1.10+57 (2026-06-11) — notification taps actually route + highlights survive scrolling
- **Tapping a notification now opens the session it names.** The tap's payload was being dropped before any routing ran (the handler was registered in the wrong place) — your "said fd-dev, sent me to raserver" reports. The tap now routes immediately, including when the app was fully closed. (#878)
- **URL/path highlights survive scrolling into history.** A +56 regression could permanently drop a highlight once its line scrolled up; also fixed a scroll-to-top paint glitch where taps on a highlight resolved against stale rows. (#883)
- **Bug-report captures hold a 3–4× longer window**, so "it just happened" reports stop missing the moment. (#879)

## v0.1.10+56 (2026-06-10) — path highlights stop at shell syntax + stray highlights cleared
- **A path next to shell syntax highlights just the path.** A line like `/path/to/script 2>&1 > /tmp/out; echo …` was highlighting the whole command as one "file"; the path detector now stops at shell delimiters (`; | & > <`, quotes) so only the real paths light up. (#874)
- **Stray leftover highlight boxes are cleared.** A URL/path highlight whose line scrolled away or got redrawn with different text no longer lingers as an empty box floating over unrelated content — the anchor is dropped as soon as its text is gone. (#873)
- **Notification-routing diagnostics.** Added capturable telemetry around the tap→session hand-off (which pending entry won the timing race, which session the app actually activated) so a wrong-route can finally be read from an uploaded report. (routing fix pending a capture)

## v0.1.10+55 (2026-06-10) — ~ paths work + notification taps land on the right server
- **The file browser handles `~` paths.** Navigating to `~/.claude/...` failed with a raw SFTP error because SFTP doesn't expand `~`; it's now expanded to your home dir, and a missing folder shows a clean "Folder not found" instead of a raw error. (#867)
- **Notification taps land on the right server, reliably.** A tap could resolve to a recently-active *different* server under a timing race; the pending-focus now seq-stamps so the server you actually tapped wins. Also added diagnostic logging that lands in the uploaded report, so any remaining misroute is now traceable. (#870)

## v0.1.10+54 (2026-06-10) — URL highlights are tappable, aligned, and cleaner
- **Tapping a highlighted URL works again, and the highlight no longer sits off-by-a-line.** The bubble and the tappable area were using different scroll offsets, so during/after a scroll the URL looked like it was at one line but the tap landed on another (→ it just selected text). Both now use the same painted offset — tap lands on the URL, and the highlight tracks scroll. (#863)
- **Cleaner URL chip** — vertically centered on the text, a little horizontal padding, and the redundant underline removed. (#864)

## v0.1.10+53 (2026-06-10) — one-tap back to terminal + notification taps land on the right session
- **X to return to the terminal in one tap.** The file browser and the text/markdown/PDF viewers now have a top-right close button that jumps straight back to the terminal from any folder depth — no more backing out level by level. (#855)
- **Tapping an attention notification opens the right session.** Tapping e.g. an fddev notification now lands on fddev even if it reconnected (got a new session id) — it falls back to the live session for that server instead of leaving you on whatever was open. (#857)

## v0.1.10+52 (2026-06-10) — markdown renders + switching sessions is quiet
- **Markdown files render now.** A `.md`/`.markdown` file opens formatted (headings, bold, lists, links, code, tables) instead of raw text, with a top-bar toggle to flip to raw source. Edit-and-save-back is a follow-up (#859). (#854)
- **Switching to a session no longer pops a redundant "needs attention" for it.** A bell replayed in the catch-up burst right after you switch to a session is now ignored — you just moved there, you can see it. (#856)

## v0.1.10+51 (2026-06-10) — tap a "build ready" notification to open the link
- **Attention notifications with a URL are now tappable to open it.** When a signal's text carries a link (e.g. your dev-loop emits `Build ready: https://…`), tapping the notification opens that URL in your browser (and focuses the session). Finish a build remotely → tap → install, no scrolling. (#710) — to surface the link, emit it via the bell/OSC-9 hook (`printf '\033]9;Build ready: <url>\007'`); I can wire the release script to do this automatically.

## v0.1.10+50 (2026-06-10) — reconnecting no longer spams notifications
- **Reconnecting a session no longer bubbles up notifications.** A bell replayed during the reconnect catch-up (old/historical, not a live "Claude needs you" moment) is now ignored — only genuinely live output after the session settles posts a notification. Applies to first connect too. Combined with +49's per-server dedup + naming, reconnect is quiet. (#851) — this stacks on +49's notification fixes; install this to get all of them.

## v0.1.10+49 (2026-06-09) — notifications that make sense + no keyboard-hide layout glitch
- **Attention notifications are fixed end-to-end.** The persistent notification no longer sits on "Connecting…" — it shows live state ("Connected — N sessions"). Attention alerts now **name the server** (e.g. "raserver — IT"), so two servers never look identical; a single Claude event reaching two sessions on one host shows **one** alert (not duplicates); and you're **not pinged for a host you're already looking at**. Device-validated: foregrounded on a host → bells suppressed. (#847) — to also get the tmux *window* name in the alert, add the `alert-bell` hook to `~/.tmux.conf`.
- **Keyboard hide no longer scrambles the terminal.** Hiding the keyboard was firing a storm of resizes across every session, overgrowing the grid and duplicating/ghosting content. Resizes that don't actually change size are now dropped, and the keyboard-hide resize settles once instead of thrashing. (#848)

## v0.1.10+48 (2026-06-09) — Copy actually lands in the clipboard (and paste history)
- **Copy now reliably puts text in the Android clipboard — including Gboard's paste history.** Copies were being written with a blank label, so the system showed the preview chip but the clip didn't surface in your clipboard history (it looked "empty until tapped"). Every copy (URL, selection, path, compose, diagnostics) now writes a properly-labeled clip natively and **reads it back to confirm it's really there** before saying "Copied". **Verify:** copy a URL → it shows in Gboard's clipboard history right away and pastes anywhere. (#845)

## v0.1.10+47 (2026-06-09) — your typing survives an accidental compose close
- **Closing/disabling the compose box no longer loses what you typed.** If you dismiss compose (X, toggle-off, switching sessions) with text still in it, that text is now kept two ways: it **reappears in the box when you reopen** compose, and it's also pushed into the **▲ history buffer** so the up-arrow can recall it. Empty input is ignored; sending/clearing drops the draft as before. **Verify:** type without sending, hit X, reopen compose → your text is back (and on ▲). (#842)

## v0.1.10+46 (2026-06-09) — Claude attention notifications (jump to the session that needs you)
- **MobiSSH now notifies you when an agent needs your attention.** When Claude is awaiting input/permission or finishes — any terminal bell or OSC 9/777 notification — a high-priority notification fires, even for a backgrounded or non-active session, and tapping it jumps straight to that session (and, under tmux, toward the source window). It's suppressed when you're already looking at that session. **Inside tmux, add the one-line `alert-bell` hook to `~/.tmux.conf`** so the signal carries through tmux's redraw (a plain shell works as-is). **Verify:** let Claude await your input (or `printf '\a'`) → a "Claude needs attention" notification appears; tap it → you land on that session. (#840)

## v0.1.10+45 (2026-06-09) — full disconnect telemetry (to fix silent drops at the root)
- **Every disconnect now records its cause + how long the session was dead before we noticed + a periodic liveness heartbeat** in the diagnostic log (battery-safe — piggybacks the existing tick, no new timer). The measurement layer behind the "disconnected with no indication" fix. **Hit Feedback after any disconnect or silent freeze** and the log captures exactly what happened, so the silent-drop detection can be built + validated from real data. (#838)

## v0.1.10+44 (2026-06-09) — disconnects are now diagnosable (telemetry)
- **Groundwork for the "disconnected with no indication" fix.** Session state changes are now recorded in the diagnostic log (they weren't before), and the wasteful per-frame fit-logging that was flooding the log while the terminal is offstage is fixed. **If you hit a disconnect with no indication again, tap Feedback** — the log will now show exactly what happened, so the silent-drop detection can be fixed at the root. (#836)

## v0.1.10+43 (2026-06-09) — URLs/paths detect again inside tmux
- **URL & path highlighting works inside tmux again.** The +41 fix that stops highlighting inside vim was too broad — tmux also uses the full-screen buffer, so it accidentally turned detection off for your whole tmux session. Now detection is suppressed only in true full-screen apps (vim/less — no mouse mode) and runs normally in tmux (mouse mode). **Verify:** a URL in tmux output gets its bubble again. (#834)

## v0.1.10+42 (2026-06-09) — Copy works after the screen redraws
- **Copy now works even after the screen updates under your selection.** A remote redraw (e.g. the tmux status-bar clock ticking ~1s after you select) was clearing the selection, so Copy said "no selection" though it still looked highlighted. The selected text is now remembered until you dismiss it (tap away) — Copy returns it reliably. (#828)

## v0.1.10+41 (2026-06-09) — bigger arrows + much less path-detection noise
- **Bigger, solid keybar arrow & nav keys** — filled directional icons (← ↑ ↓ →) and distinct Home/End/PgUp/PgDn glyphs, larger and easier to tell apart (bar height unchanged). (#823)
- **No URL/path highlighting inside vim** (or any full-screen app) — heuristic detection is for shell output, so it's off on the alt-screen; genuine embedded (OSC-8) links still work everywhere. (#824)
- **Script paths stop false-matching** — a path with shell variables or globs (`${UID}`, `*`) is no longer underlined as a tappable file. (#826)

## v0.1.10+40 (2026-06-09) — disconnected sessions stay reconnectable (recents fixed)
- **A disconnected session no longer vanishes.** It now appears under an **"Active Sessions"** group on the home/Connect screen with a Reconnect button, and your **Recent Sessions list stops disappearing** when you disconnect or hit "Reconnect all" — the recent list now shows only at a true cold start, and live-but-dropped sessions live in Active Sessions instead. Completes the session-state rework. **Verify:** connect, disconnect → the session stays on the home screen with Reconnect (doesn't vanish); Reconnect-all keeps the list visible. (#809)

## v0.1.10+39 (2026-06-08) — dropped sessions show a status dot + Reconnect
- **A dropped/disconnected session now shows its state and a Reconnect button** instead of looking live or making you ✕ it. The session menu shows a color status dot per session (connecting / reconnecting / failed / disconnected) with the reason; **tap Reconnect to revive it** (it also auto-attempts), or ✕ to forget it. **"Reconnect all"** appears when any session is down. **Verify:** drop a session (kill its connection) → it shows amber/red + Reconnect; tap → live shell returns. (#817) (Recents reconciliation — so disconnected sessions also stop vanishing from the Recent list — is the next slice.)

## v0.1.10+38 (2026-06-08) — compose action pills cleaned up
- **Fix / Copy / Paste are now one consistent pill, flush-right on the compose box's top border** — no longer overlapping your text, and the row they used to occupy is reclaimed for the text area. (#819)

## v0.1.10+37 (2026-06-08) — URL copy fixed + no more off-by-line highlight
- **Tapping a URL copies the real URL again** (single-line URLs too). Empty embedded-link terminators were anchoring an empty payload, so it copied nothing yet still said "Copied URL" — now an empty match never false-copies. **Verify:** tap a URL → clipboard has the full link. (#810)
- **The URL/path highlight no longer drifts off the text while scrolling.** Instead of chasing the position mid-scroll (which kept landing a line off), it now **hides while you scroll and re-appears glued to the text once you settle** — it can't be off-by-a-line because it doesn't draw mid-scroll. Tap-to-copy still works throughout. **Verify:** scroll a tmux screen with URLs/paths → no dancing highlight; stop → it snaps onto the text. (#812)
- Under the hood: session-state hardening (folded a fragile disconnect flag into the lifecycle + auto-reconnect re-arm on resume for failed sessions) — groundwork for the Active-Sessions / reconnect UI next. (#813)

## v0.1.10+36 (2026-06-08) — smoother scroll + lower background battery
- **Scrolling does less work.** The URL/path decorator no longer rebuilds on every redraw while you scroll a busy screen (95% fewer rebuilds) — trims the overhead on top of the remote's repaint cost. The clunk scrolling a full-repaint TUI (Claude CLI) is mostly the remote rewriting the whole screen each step; this removes what we add on top. (#805)
- **Lower background battery.** The app no longer pushes a per-session snapshot every 2s while backgrounded (it stops when you're not looking and re-emits instantly on resume), skips redundant pushes, and drops the 4KB scrollback decode from the periodic path. **The session-keeping locks/keepalive are unchanged — sessions still survive sleep.** (#806) (Bigger battery levers — keepalive interval, Wi-Fi-lock release — deferred pending on-device telemetry.)

## v0.1.10+35 (2026-06-08) — URL/path markup no longer dances while scrolling
- **Fixed: the URL/path highlight "dancing" out of sync with the text while you scroll a tmux screen.** The markup was repositioning a frame *ahead* of the text repaint; it now resolves against the exact frame the terminal painted, so highlight and text move in lockstep. Captured from your trace and pinned with a frame-by-frame replay test. **Verify (device):** scroll a tmux screen with URLs/paths — the bubbles/underlines should stay glued to their text, no dancing. (#803)

## v0.1.10+34 (2026-06-08) — compose bar polish: top Copy/Paste, grip handle, flick-dock + hold-position
- **Copy/Paste are now small chips on the top edge of the compose box** — smaller and out of the way, full touch targets preserved.
- **The drag handle has a real grip**, and the header responds to gestures: **flick up → dock to top, flick down → dock to bottom, hold-then-drag → position it exactly** anywhere on screen. **Verify (device):** flick the grip up/down to dock; press-and-hold then drag to free-position. (#798)

## v0.1.10+33 (2026-06-08) — Recent Sessions quick-connect + compose history recall
- **Recent Sessions quick-connect group.** Your recently-connected hosts appear at the top of the connect screen for **one-tap reconnect** (plus "Reconnect All" when there are 2+), shown when you have no active session — PWA parity. **Verify:** connect to a host, disconnect → it appears under "Recent Sessions"; tap → reconnects. (#796)
- **Compose history recall (▲/▼).** The compose bar now remembers the commands you've sent and lets you recall them with ▲/▼ **without re-sending** — so a long command you composed isn't lost. Survives across sends, per session. **Verify:** send a few commands, open compose, ▲ cycles back through them. (#797)

## v0.1.10+32 (2026-06-08) — Feedback now captures the scroll wheel-events you send + keeps your swipes (diagnostic infra)
- **Feedback now also captures the mouse/wheel events your swipes send to tmux** (mouse-reports only — never your keystrokes) and guarantees your recent swipes stay in the log even through a resize/resume burst. Combined with the new off-device replay tool, an unresponsive-scroll report can now be reproduced exactly and fixed at the source. **To help fix the scroll: reproduce the unresponsive scroll, then hit Feedback.** (#793/#791)
- Recorder is now provably zero-overhead on the hot path (O(1) eviction).

## v0.1.10+31 (2026-06-08) — Feedback records the byte+scroll trace (to fix the sticky scroll for real) + detect URLs anywhere you scroll
- **Feedback now also captures the raw terminal byte stream + your scroll movements** (scrubbed of secrets), alongside the screenshot. This lets a scroll/repaint bug be replayed EXACTLY off-device and fixed at the source instead of guessed. **To fix the sticky-scroll: reproduce it, then hit Feedback while it's stuck** — that trace is what I need. (#790)
- **URLs and file paths now get detected wherever you scroll to**, not only near the live prompt. **Verify:** scroll up to a line with a URL/path → it gets its bubble/underline. (#787)
- (The sticky-scroll itself is NOT fixed yet — this build is the instrument to capture it; #789.)

## v0.1.10+30 (2026-06-07) — URL/path outline tracks the text while you scroll back
- **The URL bubble / file-path underline now follows the text when you scroll back.** It was positioned once and didn't re-resolve on a pure scrollback scroll, so it drifted onto the wrong line in history (it was fine live / near the bottom). Now a scroll re-positions it against the live scroll offset. **Verify:** scroll up through terminal history → a URL bubble or path underline stays hugging its actual text on every row. (#784)

## v0.1.10+29 (2026-06-06) — tap file paths to open them + view text/code files in-app
- **Tap an absolute file path in the terminal to open it in the file browser.** Paths like `/etc/hosts`, `~/notes.md`, `./build.log` now show a small folder glyph + dotted underline; **tap** opens that location in the SFTP file browser, **long-press** → Open / Copy path. (Bare *relative* paths like `src/foo` are next — they need the shell's current directory, which your shell doesn't currently report; see #777.) **Verify:** run `ls -la /etc` or print a stack trace → absolute paths get the underline; tap one → file browser opens there. (#778)
- **Text / code / markdown files open in a built-in viewer.** Tapping a `.txt`/`.dart`/`.md`/`.json`/… file in the file browser now shows it in a read-only, selectable, monospace viewer instead of downloading it; PDFs still open in the PDF viewer, unknown/binary types still download. **Verify:** browse to a text file → it opens in-app and you can scroll/select it. (#776)

## v0.1.10+28 (2026-06-06) — plain-text wrapped URLs detect + copy in full
- **A wrapped plain-text URL now bubbles + copies the whole link**, not just the first line. Most URLs in the terminal are plain text the shell/app just colors blue (no embedded hyperlink), and they wrap at the app's own width with blank padding — which defeated the previous detection. Now it figures out where the app wraps and stitches the link back together. **Verify:** a long URL that wraps → one bubble over both lines; tap/long-press copies the complete URL. (#767)

## v0.1.10+27 (2026-06-05) — record a 10s repro clip from the Feedback pill
- **Long-press "Feedback" to record a ~10-second screen burst** (tap it to stop early). It captures the screen ~5×/second — including the terminal — then opens the usual comment box and uploads the clip. Use it to show a *moving* repro (a URL wrapping, a layout/tmux quirk, a scroll glitch) instead of a single frozen screenshot. A normal single tap still grabs one screenshot. (#repro)

## v0.1.10+26 (2026-06-05) — wrapped URLs finally bubble across BOTH lines
- **A URL that wraps now gets ONE bubble over the whole link**, both lines, with the exact full URL on copy. The link was reaching the app correctly (both lines were underlined), but our detector split it on the blank padding the app leaves at the end of the first line — so only the first line bubbled. Fixed: the link is now grouped by its identity, not by unbroken runs. **Verify:** view this conversation (or any gh/Claude output) in tmux → a wrapped URL bubbles end-to-end; long-press → Open / copy gives the complete link. (#767)

## v0.1.10+25 (2026-06-05) — OSC-8 links now work THROUGH tmux (the real fix)
- **URLs in tmux are now detected exactly.** tmux was silently stripping the embedded hyperlink because MobiSSH didn't advertise hyperlink support; the app now identifies itself so tmux forwards the link. So a URL from Claude CLI / gh inside tmux gets ONE bubble over the whole (even wrapped) link and **tap-to-copy copies the exact full URL**. This is what +22..+24 were chasing — the detection was right, tmux just wasn't passing the link through. **Verify:** view this conversation (or any gh/Claude output) in tmux → a wrapped URL bubbles end-to-end; long-press → Open / copy gives the complete link. (#767/#771)

## v0.1.10+24 (2026-06-05) — exact URLs via OSC-8 hyperlinks (wrap-proof) + copy fix
- **URLs from modern tools (Claude CLI, gh, …) are now detected exactly** by reading the hyperlink the tool already embeds — so a URL that wraps across lines gets ONE bubble over the whole link, and **tap-to-copy copies the exact full URL** (no more partial). This is wrap/indent/tmux-proof because the link target is carried in the text, not guessed from layout. Plain-text URLs (older tools) still use the visual detector. (#767)
- **Install page now shows the full version** (e.g. 0.1.10+24) next to the build date.

## v0.1.10+23 (2026-06-05) — wrapped URLs bubble across BOTH lines (tmux too)
- **A URL that wraps onto a second line now bubbles the whole link**, not just the first line. tmux hard-wraps without the terminal's soft-wrap flag, so the detector now also joins by the pane width — while still keeping two adjacent URLs separate and ignoring bullet/indented lines. **Verify:** in tmux, print a URL long enough to wrap → the bubble should cover both rows; long-press either half opens the whole URL (#767).

## v0.1.10+22 (2026-06-05) — URLs get a tappable bubble + diagnosable sessions
- **URLs now show a rounded "bubble" outline** hugging the link — even across a line wrap — instead of a fill/underline. Clearer, doesn't clash with underlined text. Tap to copy, long-press to open. **Verify:** print a long URL that wraps and a shorter one near it → each gets its own bubble, text stays readable, no bleed between them (#767).
- **Frozen/disconnected-session reports are now diagnosable** — the session lifecycle log (resume/reconnect probe outcomes) now actually reaches the feedback upload, so a stuck-session report carries the evidence to fix it (#766).

## v0.1.9+21 (2026-06-05) — wrapped URLs highlight precisely
- **A URL that wraps across lines now highlights as exactly one link** — using the terminal's own soft-wrap info instead of guessing from line width. No more bleeding the highlight across nearby URLs or capturing only part of a wrapped one; long-press resolves the whole URL from either line (#764).

## v0.1.9+20 (2026-06-05) — frozen sessions detected on unlock
- **A frozen session is now caught on unlock** — after a long time away, if a session's remote shell is dead/frozen (even though SSH still "answers"), the app nudges it and, if it's truly unresponsive, flips it to reconnecting instead of leaving it frozen under a green dot. Healthy/idle sessions are untouched. **Device test:** lock the phone a long while → unlock → a frozen session should recover on its own. The exact outcome is now logged in Diagnostics (and the feedback upload) so any miss is diagnosable (#759).

## v0.1.9+19 (2026-06-04) — selection clears when the content under it changes
- **Touch selection no longer lingers over redrawn content** — after you select, a tmux/remote redraw (or live output) now clears the selection instead of leaving the highlight stranded on whatever scrolled into its place. A pure scrollback swipe still keeps + tracks the selection; tap-to-dismiss unchanged (#760).

## v0.1.9+18 (2026-06-04) — URL highlight drawn inside the terminal (no more drift)
- **URL highlight is now painted by the terminal itself** (forked flterm), using its real cell metrics — so it sits exactly on the URL on every row and tracks scroll/wrap automatically. This replaces the overlay that kept drifting (#748/#699/#723). It now shows as a subtle tint on the URL rather than an underline — tell me if you'd rather have the underline back. (#755 — foundation for OSC-8 links + path links next.)

## v0.1.9+17 (2026-06-04) — shorter keybar + URL highlight on scroll/wrap
- **Shorter keybar** — collapsed the margin + padding so the bar is noticeably less tall; the key labels/glyphs are the same readable size (#752).
- **URL highlight clears when you scroll** — no more stale underline floating over shifted text; it disappears during a scroll and re-applies once it settles (#750).
- **Wrapped URLs** — the matcher joins soft-wrapped rows so a link spanning two lines underlines both (full-width wraps; #751). *If a specific wrapped URL still misses its 2nd line, tell me — there's a known trailing-pad edge I'll harden.*

## v0.1.9+16 (2026-06-04) — URL underline alignment
- **URL underlines now hug the text** — the highlight sat in the gap below the glyphs (worse further down the screen); it's now anchored to each line's baseline so it underlines the URL cleanly on every row (#748).

## v0.1.9+15 (2026-06-04) — long-press a URL to Open it
- **Long-press a URL in the terminal → Copy / Open menu** — single-tap still copies; long-press now opens a menu with **Open in browser** (and Copy). Finishes the URL feature on the ghostty terminal (#734).

## v0.1.9+14 (2026-06-04) — keep sessions alive through sleep
- **Sessions should survive an ordinary sleep now** — the app holds a WiFi lock while sessions are live (so the radio doesn't sleep mid-session) and asks once to be exempted from battery optimization (accept the prompt on first connect, or grant via **Settings → "Allow background battery use"**). With that, ordinary screen-off periods shouldn't drop your sessions (#738). **Device test:** connect 2-3 sessions, lock the phone 5/15/60 min, wake → still live. (Very long/deep Doze can still drop any app's network — that's where #737's graceful reconnect catches it.)

## v0.1.9+13 (2026-06-04) — never-frozen wake + session/keyboard/file-browser UX
- **Wake-from-sleep no longer freezes sessions** — on resume the app probes each session and a dead one reconnects (visible "reconnecting…") instead of silently eating input on a stale screen (#737). (Note: separately, keeping sessions alive *through* sleep is still coming — #738.)
- **Session menu shows each session's profile color swatch** — quick visual identification across sessions (#739).
- **Swiping the session bar keeps the keyboard up** — switching sessions no longer dismisses the keyboard / jumps the bar out from under your finger (#741).
- **File browser shows which server you're browsing** + a one-tap **back to that server's terminal** (#740).

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
