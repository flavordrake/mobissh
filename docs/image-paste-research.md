# Image/Binary Clipboard Paste-Through Research

Research for issue #216: supporting image/binary clipboard paste-through for AI TUI tools
(Claude Code) running over SSH in MobiSSH.

## Summary

The key finding is that **there is no standard terminal protocol for passing image data to
remote processes over SSH**. Apple Terminal, iTerm2, and similar emulators do not forward
clipboard image data to running processes via escape sequences. Instead, AI TUI tools like
Claude Code access the OS clipboard directly using platform-native APIs. Over SSH, those
APIs query the remote machine's clipboard — which has no knowledge of the mobile device's
clipboard content. This gap requires a custom solution.

---

## Q1: How does Apple Terminal pass image data to local processes?

**Finding: It does not. Apple Terminal does not pass image data to processes via any escape
sequence or stdin mechanism.**

When a user pastes (Cmd+V) in Apple Terminal, the terminal intercepts the paste event and
forwards only text content to the running process via stdin. Binary/image data in the
system clipboard is silently discarded by the terminal before it reaches the process.

Applications that appear to "accept image paste" in Apple Terminal (including Claude Code)
do so by directly querying the macOS system clipboard using OS APIs, triggered by
intercepting the Ctrl/Cmd+V keypress at the application's own event loop — not by receiving
data from the terminal.

**iTerm2 vs Apple Terminal:**
- Both behave the same way for clipboard paste: only text is forwarded via stdin.
- iTerm2 defines proprietary escape sequences for clipboard operations:
  - `OSC 1337 ; CopyToClipboard=[name] ST` ... `OSC 1337 ; EndCopy ST` — write text to clipboard
  - `OSC 1337 ; Copy=:[base64] ST` — write base64-encoded text to clipboard
  - These are write-only and text-only; there is no iTerm2 escape sequence for a process to
    receive pasted image data.
- Standard OSC 52 (see Q4) is the closest to a cross-terminal clipboard protocol, but it
  also supports only text.

Sources:
- iTerm2 escape codes: https://iterm2.com/documentation-escape-codes.html
- xterm OSC 52: https://www.xfree86.org/current/ctlseqs.html

---

## Q2: What protocol does Claude Code use to receive pasted image data?

**Finding: Claude Code uses platform-native OS clipboard APIs, not terminal escape
sequences.**

Reverse-engineering of the Claude Code binary (reported in issue anthropics/claude-code#29776)
reveals two-step AppleScript execution on macOS:

**Step 1 — Check for PNG in clipboard:**
```
osascript -e 'the clipboard as «class PNGf»'
```

**Step 2 — Save to temp file (if PNG detected):**
```
osascript -e 'set png_data to (the clipboard as «class PNGf»)'
          -e 'set fp to open for access POSIX file "/tmp/claude_cli_latest_screenshot.png" with write permission'
          -e 'write png_data to fp'
          -e 'close access fp'
```

On Linux, the equivalent mechanism uses `xclip` or `wl-paste` with explicit image MIME types
(e.g., `xclip -selection clipboard -t image/png -o`).

**What this means for SSH:** Claude Code running on a remote server uses
`osascript`/`xclip` to query the remote machine's system clipboard. The remote machine has
no knowledge of what is in the mobile device's clipboard. No standard SSH mechanism
propagates clipboard image data from client to server.

**Known format:** PNG (`image/png`, macOS UTI `public.png`). BMP is also tracked as a bug
(anthropics/claude-code#25935). JPEG and other formats are not confirmed.

Sources:
- anthropics/claude-code#29776 (macOS ENOBUFS bug revealing implementation details)
- anthropics/claude-code#25672 (tmux clipboard issue)
- anthropics/claude-code#25935 (BMP format not recognized on WSL2)

---

## Q3: What does `navigator.clipboard.read()` return for image data on mobile?

**Finding: Returns `ClipboardItem` objects with `image/png` MIME type. Browser support is
broad but not universal on mobile, and iOS requires a user-visible prompt.**

### API Surface

```javascript
// Read image from clipboard
const items = await navigator.clipboard.read();
for (const item of items) {
  if (item.types.includes('image/png')) {
    const blob = await item.getType('image/png');
    // blob is a Blob of type 'image/png'
    const arrayBuffer = await blob.arrayBuffer();
    // arrayBuffer contains raw PNG bytes
  }
}
```

Key behaviors:
- Requires HTTPS (secure context).
- Returns `image/png` regardless of the original image format — browsers normalize to PNG
  even if the source was JPEG. (Source: MDN, confirmed by example in MDN documentation.)
- Returns a `Blob` (not a string); must use `blob.arrayBuffer()` or `blob.text()`.
- Requires the `clipboard-read` permission (Chrome/Chromium) or a user-visible paste prompt
  (Safari).

### Browser Support

| Browser | Support | Notes |
|---|---|---|
| Chrome for Android | Yes (Chrome 101+) | Permission prompt (`clipboard-read`) |
| Safari on iOS | Yes (Safari 13.4+) | User-visible paste prompt (ephemeral; cannot be pre-granted) |
| Firefox for Android | Yes (Firefox 127+) | |
| Samsung Internet | Partial | May require user gesture |

**iOS note:** Safari does not support `PermissionDescriptor { name: 'clipboard-read' }`.
It instead shows an OS-level paste confirmation dialog when `clipboard.read()` is called.
This is the same prompt as for text paste. The user must tap "Paste" each time — there is
no persistent grant.

**Baseline status:** "Baseline 2024 — Newly available since June 2024."

Sources:
- MDN Clipboard.read(): https://developer.mozilla.org/en-US/docs/Web/API/Clipboard/read
- MDN Clipboard API browser compatibility: https://developer.mozilla.org/en-US/docs/Web/API/Clipboard_API#browser_compatibility

---

## Q4: Is there a standard terminal escape sequence for image paste?

**Finding: No. There is no standard terminal escape sequence for passing image data to a
running process. Existing protocols cover text-only clipboard and image display only.**

### OSC 52 (Clipboard)

OSC 52 is the closest standard for clipboard operations in terminals:

```
OSC 52 ; Pc ; Pd BEL
```

- `Pc`: selection type (`c` for clipboard, `p` for primary, etc.)
- `Pd`: base64-encoded clipboard data (text only)

OSC 52 allows a remote process to write to the local terminal's clipboard and to query the
local clipboard. It is implemented in xterm, kitty, and some other terminals. However:

- The data parameter (`Pd`) is defined as base64-encoded **text**. No binary MIME type
  support is defined in the spec.
- The xterm.js clipboard addon implements OSC 52 using only `navigator.clipboard.writeText()`
  and `navigator.clipboard.readText()` — explicitly text-only.
- There is no OSC 52 extension for image data in any terminal specification.

### Bracketed Paste Mode (DEC mode 2004)

Bracketed paste mode wraps pasted text in `\x1b[200~` ... `\x1b[201~`. It is designed
to prevent pasted content from being interpreted as commands. It applies to text only.

### Image Display Protocols (not relevant for input)

| Protocol | Purpose | Input? |
|---|---|---|
| Sixel | Render pixel graphics in terminal | No — output only |
| iTerm2 inline images (OSC 1337) | Render images in iTerm2 | No — output only |
| Kitty graphics protocol (APC G) | Render pixel graphics | No — output only |

None of these define a mechanism for sending image data to a process's stdin or for
a remote process to receive an image from the user's clipboard.

**Conclusion:** No standard exists. A custom protocol is required.

Sources:
- xterm OSC 52 spec: https://www.xfree86.org/current/ctlseqs.html
- Kitty graphics protocol: https://sw.kovidgoyal.net/kitty/graphics-protocol/
- xterm.js clipboard addon (OSC 52 implementation): https://github.com/xtermjs/xterm.js/blob/master/addons/addon-clipboard/src/ClipboardAddon.ts

---

## Q5: What does xterm.js do with non-text paste events?

**Finding: xterm.js does not handle binary or image clipboard data during paste. Non-text
content is dropped. The `onBinary` event is not related to paste.**

### `onData` event

Fires when data should be sent to the PTY. It is triggered by text paste events and fires
with a `string`. This is what MobiSSH's WebSocket bridge uses to forward typed input.

### `onBinary` event

Documented as handling "non UTF-8 conformant binary messages." Despite the name, it is
**not** triggered by paste events. It is currently used only for certain mouse report
sequences that produce non-UTF-8 byte values. The xterm.js documentation notes:
> "currently only used for a certain type of mouse reports that happen to be not UTF-8
> compatible."

### `paste()` method

`terminal.paste(text: string)` writes text to the terminal with bracketed paste wrapping.
It takes only a string.

### What happens on image paste

When a user pastes from the OS clipboard in a browser:

1. The browser `paste` DOM event fires on the focused element (the xterm.js canvas).
2. `event.clipboardData.getData('text/plain')` is used for text.
3. `event.clipboardData.getData('image/png')` returns an empty string — binary MIME types
   are not accessible via `clipboardData.getData()`.
4. No xterm.js callback fires for image data. The image is silently dropped.

To access image data, `navigator.clipboard.read()` must be called explicitly (not via the
`paste` event's `clipboardData`).

**Implication for MobiSSH:** The existing xterm.js paste handler in `public/modules/` only
handles `text/plain`. A separate code path using `navigator.clipboard.read()` must be
added to detect and handle `image/png` clipboard items.

Sources:
- xterm.js Terminal API: https://xtermjs.org/docs/api/terminal/classes/terminal/
- xterm.js clipboard addon: https://github.com/xtermjs/xterm.js/blob/master/addons/addon-clipboard/src/ClipboardAddon.ts

---

## Q6: Proposed Implementation Path for MobiSSH

**Finding: A custom end-to-end protocol is required. No off-the-shelf solution exists.**

### The Core Problem

Claude Code reads clipboard images via OS-native APIs (`osascript`, `xclip`) that query the
local machine's clipboard. Over SSH, "local machine" is the remote server, which has no
access to the mobile device's clipboard. Standard SSH does not propagate clipboard content.

### Data Flow

```
Mobile clipboard
  -> navigator.clipboard.read()       [MobiSSH frontend: public/modules/]
  -> detect image/png ClipboardItem
  -> read as ArrayBuffer
  -> base64-encode
  -> WebSocket message (new type)     [MobiSSH WebSocket protocol]
  -> server/index.js receives
  -> write to temp file on server     [e.g., /tmp/mobissh_paste.png]
  -> inject into remote clipboard     [platform-specific step]
  -> Claude Code reads clipboard      [osascript / xclip]
```

### Step-by-Step

**1. Frontend: detect image on paste (public/modules/)**

On paste keypress (Ctrl+V / Cmd+V), before sending to xterm.js:

```javascript
const items = await navigator.clipboard.read();
const imageItem = items.find(item => item.types.includes('image/png'));
if (imageItem) {
  const blob = await imageItem.getType('image/png');
  const buf = await blob.arrayBuffer();
  const b64 = btoa(String.fromCharCode(...new Uint8Array(buf)));
  ws.send(JSON.stringify({ type: 'clipboard-image', data: b64 }));
  return; // do not send to xterm.js
}
// fall through to normal text paste
```

**2. WebSocket protocol (server/index.js)**

Add handling for the new `clipboard-image` message type. Currently MobiSSH sends raw
terminal data as binary WebSocket frames. A new JSON-structured message type must be
defined and distinguished from raw PTY input.

**3. Server: receive image and inject into remote clipboard**

The server receives base64-encoded PNG and must make it available to Claude Code.

On **Linux** (recommended target; MobiSSH Docker container is Linux):
```bash
echo "<base64>" | base64 -d | xclip -selection clipboard -t image/png
# requires: xclip, DISPLAY (or Xvfb)
```

Or using xdotool / wl-clipboard (Wayland):
```bash
echo "<base64>" | base64 -d | wl-copy --type image/png
```

On **macOS** (if server is macOS):
```bash
osascript -e 'set the clipboard to (read "/tmp/mobissh_paste.png" as «class PNGf»)'
```

**4. Timing**

After injecting, MobiSSH must signal Claude Code to paste. Claude Code responds to Ctrl+V.
The server should inject the clipboard, then send `\x16` (Ctrl+V) through the PTY:

```javascript
sshStream.write('\x16');
```

### Files Requiring Changes

| File | Change needed |
|---|---|
| `public/modules/` (likely `terminal.js` or `input.js`) | Add `navigator.clipboard.read()` call on paste, detect image MIME type, send new WS message type |
| `server/index.js` | Parse new `clipboard-image` WS message type, write image to temp file, inject into system clipboard, send Ctrl+V to PTY |
| `public/app.js` or WS message protocol | Define new message type constant |

### Blockers and Unknowns

**Blocker 1: X11/Wayland display requirement on Linux server.**
`xclip` requires `DISPLAY` to be set. Inside a headless Docker container (MobiSSH's
production setup), there is no X11 display. `Xvfb` (virtual framebuffer) would need to be
installed in the container and started at launch. `wl-copy` (wl-clipboard) requires a
Wayland compositor — also not present in headless Docker.

Alternative [SPECULATION]: A custom clipboard broker process (e.g., a small daemon that
listens for images and stores them in a known file path) could bypass X11 entirely. Claude
Code would need to be modified to check this custom path, which is not feasible.

**Blocker 2: Claude Code clipboard integration is opaque.**
The `osascript`/`xclip` mechanism was reverse-engineered from bug reports, not official
docs. If Claude Code changes how it reads clipboard data, this implementation breaks
silently.

**Blocker 3: iOS Safari clipboard permission.**
iOS Safari requires a user-visible paste dialog every time `navigator.clipboard.read()` is
called. This may be acceptable UX (user taps "Paste" in the iOS prompt) but cannot be
eliminated.

**Blocker 4: WebSocket message framing.**
MobiSSH's current WebSocket protocol sends raw PTY bytes as binary frames. Adding a JSON
message type requires the server and client to distinguish JSON control messages from raw
PTY data. This requires a protocol versioning or framing change.

**Unknown: Does Claude Code on Linux use `xclip` or a different mechanism?**
The Linux clipboard path was inferred from bug reports (anthropics/claude-code#29204,
#29776). The exact tool and exact command line arguments are not confirmed from source code.

### Verdict

Implementation is feasible but requires coordinated work across frontend, WebSocket
protocol, and server-side infrastructure. The Docker container would need `xclip` and
`Xvfb` added, plus startup changes. This is medium complexity — the main risk is the X11
dependency in headless Docker, which is the only discovered path to inject image data into
the remote clipboard on Linux.

A simpler but more limited alternative: write the image to a well-known temp path
(`/tmp/mobissh_paste.png`) and print a shell command the user can run to have Claude Code
pick it up manually (e.g., `/add /tmp/mobissh_paste.png`). This avoids X11 entirely but
requires user action. [SPECULATION: this assumes Claude Code's `/add` command supports
image files; not confirmed.]
