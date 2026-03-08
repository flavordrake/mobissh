# Research: TUI Coding Agent Rendering/Input Issues Through xterm.js

Issue: #7
Date: 2026-03-08
Status: Research spike (no code changes)

## Context

MobiSSH proxies SSH sessions through a WebSocket bridge and renders them with
xterm.js in the browser. TUI coding agents (Claude Code CLI, opencode, aider,
etc.) use rich terminal features. This document catalogues which features they
rely on, whether xterm.js 6.0.0 supports them, and where gaps exist.

## MobiSSH Current State

- **xterm.js version**: 6.0.0 (vendored in `public/vendor/xterm.min.js`)
- **addon-fit**: 0.11.0
- **Terminal config** (`src/modules/terminal.ts` line 54-61):
  - `convertEol: false` (correct for SSH PTY output)
  - `cursorBlink: true`
  - `scrollback: 5000`
- **Input routing**: Hidden `#imeInput` textarea captures keystrokes; `KEY_MAP`
  in `src/modules/constants.ts` maps DOM key names to VT sequences
- **Mouse/scroll**: Touch scroll translates to SGR mouse reports when
  `mouseTrackingMode` is active (`src/modules/ime.ts` lines 366-398)
- **Existing tests**: `tests/tui.spec.js` covers ANSI colors, box-drawing,
  alternate screen, DECSET modes, function keys F1-F12, navigation keys,
  Ctrl combos, and key bar buttons

## 1. Terminal Features Used by TUI Frameworks

### Ink / React-Ink (used by Claude Code CLI)

Claude Code's TUI is built on React with a custom Ink-derived renderer. It uses:

| Feature | Escape Sequence | Purpose |
|---|---|---|
| Alternate screen | CSI ?1049 h/l | Full-screen UI without polluting scrollback |
| Cursor hide/show | CSI ?25 l/h | Suppress cursor during redraws |
| Cursor positioning | CSI row;col H | Absolute cell addressing |
| Truecolor (24-bit) | CSI 38;2;R;G;B m | Rich syntax highlighting |
| SGR attributes | CSI 1m, 2m, 3m, 4m, 7m | Bold, dim, italic, underline, reverse |
| Styled underlines | CSI 4:3 m (curly), 4:2 m (double) | Diagnostic squiggles, spell-check |
| Colored underlines | CSI 58;2;R;G;B m | Underline color independent of text |
| Erase in display | CSI 2J, CSI J | Clear screen |
| Erase in line | CSI 2K, CSI K | Clear current line |
| Bracketed paste | CSI ?2004 h/l | Distinguish pasted text from typed |
| Synchronized output | CSI ?2026 h/l (Mode 2026) | Batch rendering to prevent tearing |
| Mouse tracking | CSI ?1000h, ?1002h, ?1006h | Click and scroll interaction |

[FACT] Anthropic rewrote Claude Code's renderer to diff individual terminal cells
and emit minimal ANSI sequences instead of full redraws, reducing flicker by ~85%.
Source: https://steipete.me/posts/2025/signature-flicker

[FACT] The original Ink renderer space-pads every line to terminal width with
reverse-video escapes; the rewritten renderer avoids this.
Source: https://github.com/anthropics/claude-code/issues/23014

### BubbleTea (used by opencode)

opencode is built with Go's BubbleTea framework (Elm Architecture for terminals).

| Feature | Escape Sequence | Purpose |
|---|---|---|
| Alternate screen | CSI ?1049 h/l | Full-screen TUI |
| Synchronized output | CSI ?2026 h/l | Tear-free rendering (BubbleTea v2) |
| Mouse tracking | CSI ?1000h, ?1003h, ?1006h | Click/scroll in UI panels |
| Bracketed paste | CSI ?2004 h/l | Paste handling in editor panes |
| 256-color | CSI 38;5;N m | Theme colors |
| Truecolor | CSI 38;2;R;G;B m | Syntax highlighting |
| Box-drawing | Unicode U+2500-U+257F | Panel borders |
| Cursor keys (app mode) | CSI ?1 h (DECCKM) | Arrow keys in menus |
| Auto-wrap control | CSI ?7 l/h (DECAWM) | Layout control |

[FACT] BubbleTea v2 added `tea.EnableMode2026()` for synchronized output support.
Source: https://www.glukhov.org/post/2026/02/tui-frameworks-bubbletea-go-vs-ratatui-rust/

### Ratatui (Rust TUI library)

Used by various Rust-based terminal tools. Uses crossterm/termion backends.

| Feature | Escape Sequence | Purpose |
|---|---|---|
| Alternate screen | CSI ?1049 h/l | Full-screen rendering |
| Raw mode | (PTY config, not escape) | Unbuffered char-by-char input |
| Mouse capture | CSI ?1000h, ?1002h, ?1003h, ?1006h | Interactive widgets |
| Cursor positioning | CSI row;col H | Immediate-mode rendering |
| Styled underlines | CSI 4:N m | Decorations |
| Synchronized output | CSI ?2026 h/l | Frame buffering |

## 2. Commonly Used Escape Sequences (Summary)

**Universally used by all three frameworks:**
- CSI H (cursor position), CSI J / CSI K (erase)
- CSI ?1049 h/l (alternate screen buffer)
- CSI ?25 h/l (cursor visibility)
- CSI 38;5;Nm / CSI 38;2;R;G;Bm (256-color / truecolor)
- CSI 1m, 2m, 3m, 4m, 7m (SGR attributes)
- CSI ?2004 h/l (bracketed paste)

**Used by most TUI agents:**
- CSI ?1000h, ?1002h, ?1003h (mouse tracking protocols)
- CSI ?1006h (SGR mouse encoding)
- CSI ?2026 h/l (synchronized output / Mode 2026)
- CSI 4:Nm (styled underlines: single, double, curly, dotted, dashed)
- CSI 58;2;R;G;Bm (colored underlines)
- CSI ?1h / CSI ?1l (DECCKM: application/normal cursor keys)
- CSI ?7h / CSI ?7l (DECAWM: auto-wrap mode)

## 3. xterm.js 6.0.0 Support Matrix

| Feature | xterm.js 6.0.0 | Notes |
|---|---|---|
| Alternate screen (1049) | Supported | Works. Scrollback experience in alt buffer has known UX issues (xtermjs#802, #3607) |
| Cursor hide/show (25) | Supported | |
| Cursor positioning (CUP) | Supported | |
| 256-color (38;5;N) | Supported | |
| Truecolor (38;2;R;G;B) | Supported | |
| SGR bold/dim/italic/underline/reverse | Supported | |
| Styled underlines (4:N) | Supported | Added in 5.0. Canvas renderer has clipping bugs (xtermjs#4653, #4064, #4058) |
| Colored underlines (58;2;R;G;B) | Supported | Added in 5.0 |
| Erase in display/line (J/K) | Supported | |
| Bracketed paste (2004) | Supported | Since ~2017 |
| Mouse tracking (1000/1002/1003) | Supported | |
| SGR mouse encoding (1006) | Supported | |
| Application cursor keys (DECCKM, 1) | Supported | |
| Auto-wrap (DECAWM, 7) | Supported | |
| Application keypad (DECKPAM/DECKPNM) | Supported | |
| **Synchronized output (2026)** | **Supported** | **Added in 6.0.0** |
| Box-drawing characters (Unicode) | Supported | Font-dependent rendering quality |
| OSC 8 hyperlinks | Supported | Added in 5.0 |

[FACT] xterm.js 6.0.0 added synchronized output (Mode 2026) support.
Source: https://newreleases.io/project/github/xtermjs/xterm.js/release/6.0.0

[FACT] Styled underline support (curly, double, dotted, dashed) was added in 5.0
but has canvas renderer rendering bugs.
Source: https://github.com/xtermjs/xterm.js/issues/4653

## 4. Current xterm.js Version Analysis

MobiSSH uses **xterm.js 6.0.0**, which is the latest major release. Key features
added since the 5.x series that matter for TUI agents:

**6.0.0 (Dec 2025):**
- Synchronized output (Mode 2026) support -- critical for BubbleTea v2, Claude Code
- Canvas renderer addon removed (WebGL or DOM only)
- Viewport/scroll rework integrated from VS Code codebase
- Breaking: alt-to-ctrl keybinding mapping removed (needs manual rebinding)

**5.0.0 (earlier):**
- Styled underlines (CSI 4:Nm) -- curly, double, dotted, dashed
- Colored underlines (CSI 58;2;R;G;Bm)
- OSC 8 hyperlink support
- 30% bundle size reduction

Being on 6.0.0 means MobiSSH has full coverage of the escape sequences used by
modern TUI coding agents. There are no critical missing sequences.

## 5. `convertEol: false` and TUI Frameworks

MobiSSH sets `convertEol: false` (line 60 of `terminal.ts`). This is the
**correct setting** for SSH PTY connections.

- SSH PTY output already contains `\r\n` (CRLF) because the remote PTY's
  `onlcr` flag converts LF to CRLF before transmission
- Setting `convertEol: true` would double-convert: `\n` -> `\r\n` -> display
  would show extra blank lines
- TUI frameworks (Ink, BubbleTea, Ratatui) all emit explicit `\r\n` or use
  cursor positioning (CSI H) -- they don't rely on implicit LF->CRLF conversion
- tmux sessions specifically require `convertEol: false` to avoid output
  corruption in split panes

[FACT] `convertEol: false` is correct. No issues expected with TUI frameworks
over SSH PTY connections.

## 6. Input Sequences: KEY_MAP vs TUI Agent Requirements

MobiSSH's `KEY_MAP` (`src/modules/constants.ts` lines 154-172) maps:

| Key | Sequence | TUI Usage |
|---|---|---|
| Enter | `\r` | Confirm/submit |
| Backspace | `\x7f` (DEL) | Delete char |
| Tab | `\t` | Completion/focus-next |
| Escape | `\x1b` | Cancel/exit modes |
| Arrow keys | `\x1b[A/B/C/D` | Navigation (normal mode) |
| Home/End | `\x1b[H` / `\x1b[F` | Line start/end |
| PageUp/PageDown | `\x1b[5~` / `\x1b[6~` | Scroll/page |
| Delete | `\x1b[3~` | Delete forward |
| Insert | `\x1b[2~` | Insert mode toggle |
| F1-F4 | `\x1bOP` - `\x1bOS` (SS3) | Help, menus |
| F5-F12 | `\x1b[15~` - `\x1b[24~` (CSI) | Various TUI shortcuts |

### Gaps Identified

**Missing from KEY_MAP (not critical):**

1. **Application cursor mode variants**: When DECCKM (mode 1) is set, arrow
   keys should send `\x1bOA`-`\x1bOD` (SS3) instead of `\x1b[A`-`\x1b[D`
   (CSI). xterm.js handles this internally when processing key events through
   `Terminal.onKey`, but MobiSSH routes input through the hidden textarea and
   `KEY_MAP`, which always sends normal-mode sequences.

   [SPECULATION] This may cause issues if a TUI agent sets DECCKM and expects
   SS3 arrow sequences. However, most modern TUI frameworks accept both CSI
   and SS3 arrow key formats. Testing needed.

2. **Shift+Arrow / Ctrl+Arrow**: Some TUI agents use modified arrow keys for
   word movement or selection. These generate different sequences:
   - Ctrl+ArrowRight: `\x1b[1;5C`
   - Shift+ArrowDown: `\x1b[1;2B`

   [SPECULATION] These may not be captured by the current KEY_MAP. The
   hardware keyboard path may handle them, but the key bar does not provide
   these combinations.

3. **Meta/Alt key sequences**: Some TUI agents expect `\x1b` prefix for
   Alt+key combinations. MobiSSH has no Alt key bar button.

   [SPECULATION] Alt combos from hardware Bluetooth keyboards may work via
   the keydown handler, but are unavailable on touchscreen-only devices.

## 7. Mobile-Specific Issues

### Touch vs Mouse Events

TUI agents that enable mouse tracking (modes 1000/1002/1003 with SGR encoding
1006) expect X11-style mouse events. MobiSSH translates touch gestures:

- **Scroll**: Touch drag is translated to SGR mouse wheel reports when mouse
  tracking is active (`ime.ts` lines 366-398). Natural/traditional scroll
  direction is handled.
- **Click**: [SPECULATION] Single tap may not generate mouse press/release
  events that TUI agents expect for button clicks in their UI.
- **Drag selection**: xterm.js has no native touch selection (xtermjs#5377).
  MobiSSH implements custom long-press word selection (`selection.ts`).

### Virtual Keyboard Interference

- **Viewport resizing**: When the mobile keyboard appears, `visualViewport`
  height changes. MobiSSH handles this (`terminal.ts` lines 128-164) and sends
  resize messages to the SSH server. TUI apps see a legitimate terminal resize
  and redraw.
- **Rapid resize storms**: Opening/closing the keyboard triggers multiple
  resize events. Combined with synchronized output (Mode 2026), this should be
  manageable, but rapid redraws on slow connections may cause visible tearing.

  [SPECULATION] BubbleTea/Ratatui apps that redraw on every SIGWINCH could
  produce noticeable flicker on slow mobile connections.

- **IME composition conflicts**: The hidden textarea approach means IME
  composition (swipe keyboard, voice dictation) sends final committed text.
  TUI agents that expect character-by-character input should work, but
  agents relying on stdin being a real TTY for raw-mode input detection may
  behave differently.

  [FACT] The hidden textarea has `autocorrect="off"` and related attributes
  to prevent iOS from corrupting SSH commands (issue #10).

### Screen Real Estate

- Mobile screens at 14px font yield roughly 40-50 columns and 15-25 rows.
- Most TUI agents have minimum requirements:
  - Claude Code: ~80 columns for comfortable use
  - opencode: ~60 columns minimum
  - Standard TUI: ~40 columns minimum (tested in `tui.spec.js`)
- The key bar and tab bar consume vertical space, reducing available rows.

[FACT] `tui.spec.js` verifies cols >= 40 and rows >= 10 at test viewport sizes.

## Top 3 Likely Causes of Issues

### 1. Application cursor mode (DECCKM) key sequence mismatch

**Severity**: Medium
**Confidence**: Speculation (needs testing)

When a TUI agent sets DECCKM (CSI ?1h), it expects arrow keys as SS3 sequences
(`\x1bOA`). MobiSSH's `KEY_MAP` always maps to CSI sequences (`\x1b[A`). If the
input path bypasses xterm.js's internal key handling (which respects DECCKM),
arrow keys will send the wrong escape sequences.

**Impact**: Arrow key navigation may not work in TUI menus/panels.
**Mitigation**: Check xterm.js's `modes.applicationCursorKeysMode` before
choosing the arrow key sequence, or route key events through xterm.js's
`Terminal.onKey` handler instead of the custom `KEY_MAP`.

### 2. Touch-to-mouse event translation gaps

**Severity**: Medium-High
**Confidence**: Mix of fact and speculation

MobiSSH translates touch scroll to SGR mouse wheel events, but may not generate
mouse press/release events for taps. TUI agents (especially BubbleTea-based)
that render clickable buttons/links in their UI expect mouse click reports.

**Impact**: Interactive TUI elements (buttons, checkboxes, links) may be
untappable on mobile.
**Mitigation**: Translate single-tap on the terminal canvas to SGR mouse
press+release events when mouse tracking mode 1000 or 1002 is active.

### 3. Screen size too small for TUI agent minimum requirements

**Severity**: High
**Confidence**: Fact

Most TUI coding agents assume 80+ columns. Mobile screens at typical font sizes
provide 40-50 columns. Agents may:
- Refuse to start (Claude Code shows an error below 60 cols)
- Render a corrupted/wrapped layout
- Crash on arithmetic errors from negative panel widths

**Impact**: TUI agents may be unusable on phone-sized screens without reducing
font size to unreadable levels.
**Mitigation**: Auto-detect TUI agent startup (alternate screen + specific
TERM_PROGRAM values) and suggest landscape mode or font size reduction. Possibly
offer a "TUI mode" that hides the key bar and tab bar to maximize rows.

## Compatibility Matrix Summary

| Feature | xterm.js 6.0.0 | MobiSSH Input | Mobile UX |
|---|---|---|---|
| Alternate screen | OK | N/A | OK |
| Truecolor rendering | OK | N/A | OK |
| Box-drawing chars | OK | N/A | OK (font-dependent) |
| Styled underlines | OK (minor rendering bugs) | N/A | OK |
| Synchronized output | OK (new in 6.0.0) | N/A | OK |
| Bracketed paste | OK | OK (clipboard addon) | OK |
| Arrow keys (normal) | OK | OK (KEY_MAP) | OK (key bar) |
| Arrow keys (app mode) | OK (xterm internal) | Possibly wrong via KEY_MAP | Needs testing |
| Function keys F1-F12 | OK | OK (KEY_MAP) | No key bar buttons |
| Ctrl combos | OK | OK (sticky modifier) | OK (Ctrl key bar) |
| Mouse click | OK | Not translated from touch | Broken on mobile |
| Mouse scroll | OK | OK (SGR translation) | OK |
| Alt/Meta combos | OK | Hardware keyboard only | No key bar button |
| 80+ column layout | OK | N/A | Too narrow on phones |

## Sources

- xterm.js releases: https://github.com/xtermjs/xterm.js/releases
- xterm.js 6.0.0 release: https://newreleases.io/project/github/xtermjs/xterm.js/release/6.0.0
- xterm.js VT features: https://xtermjs.org/docs/api/vtfeatures/
- xterm.js synchronized output issue: https://github.com/xtermjs/xterm.js/issues/3375
- xterm.js curly underline issues: https://github.com/xtermjs/xterm.js/issues/1145, https://github.com/xtermjs/xterm.js/issues/4653
- xterm.js alternate screen: https://github.com/xtermjs/xterm.js/issues/802, https://github.com/xtermjs/xterm.js/issues/3607
- xterm.js mouse encoding: https://github.com/xtermjs/xterm.js/issues/812
- Claude Code TUI architecture: https://kotrotsos.medium.com/claude-code-internals-part-11-terminal-ui-542fe17db016
- Claude Code rendering fix: https://steipete.me/posts/2025/signature-flicker
- Claude Code space-padding issue: https://github.com/anthropics/claude-code/issues/23014
- Claude Code rendering corruption: https://github.com/anthropics/claude-code/issues/22734
- BubbleTea vs Ratatui comparison: https://www.glukhov.org/post/2026/02/tui-frameworks-bubbletea-go-vs-ratatui-rust/
- Synchronized output spec: https://gist.github.com/christianparpart/d8a62cc1ab659194337d73e399004036
- opencode TUI docs: https://opencode.ai/docs/tui/
- Ink (React terminal renderer): https://github.com/vadimdemedes/ink
