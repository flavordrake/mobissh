# Remote Clipboard Bridging Research

Research for issue #227: setting a remote machine's clipboard without interfering with the
active terminal session.

## Summary

The core challenge is that injecting clipboard data via the active PTY session (`sshStream.write()`)
interferes with whatever the user is doing in the terminal. This document surveys existing approaches
for out-of-band clipboard bridging and recommends the SSH exec-channel approach as best for MobiSSH.

The key findings:
- OSC 52 is widely deployed but text-only; no image support exists in any terminal spec.
- Existing tools (lemonade, clipper) are text-only and require installation on the remote.
- The SSH exec channel approach runs `xclip` in a separate channel, completely isolated from the PTY.
- `xclip` requires X11 (`DISPLAY`) on Linux; headless servers need `Xvfb` or `xvfb-run`.
- The simplest universal fallback is file-path delivery (upload to `/tmp/`, toast path to user).

---

## Q1: Existing Remote Clipboard Tools

### lemonade (proven)

[lemonade-command/lemonade](https://github.com/lemonade-command/lemonade) is a Go binary that
exposes clipboard operations (copy, paste, open URL) over a TCP port, designed specifically for
SSH remote use.

Architecture:
- Local machine runs `lemonade server` — a daemon that owns the local clipboard.
- Remote machine runs `lemonade copy <text>` to send text to the local machine's clipboard via TCP.
- SSH reverse port forwarding (`-R 2489:localhost:2489` in `~/.ssh/config`) tunnels the TCP
  connection back through the SSH session without touching the PTY.

Limitations:
- Text-only: `lemonade copy` accepts only string data. Binary/image support is absent.
- Requires installation of the `lemonade` binary on both client and remote server.
- The server-side daemon must be running on the client machine before SSH connects.
- No MobiSSH-specific integration path: MobiSSH runs in a browser, not on a machine that could
  host a lemonade server.

Sources:
- [github.com/lemonade-command/lemonade](https://github.com/lemonade-command/lemonade)
- [lemonade gist: how to use across machines](https://gist.github.com/bketelsen/27c2cd5b1376e72e240321baa0fbc81a)

### clipper (proven)

[wincent/clipper](https://github.com/wincent/clipper) is a macOS launch agent / Linux daemon that
exposes the local clipboard over a UNIX domain socket or TCP port. Remote machines send data to it
via SSH remote port forwarding (`-R`).

Architecture:
- Clipper runs on the local machine, listening on `~/.clipper.sock` or a TCP port.
- Remote machine connects to the forwarded socket and writes text; clipper places it in the local
  clipboard.
- Designed for vim/tmux yank workflows.

Limitations:
- Text-only: clipboard data is sent as raw bytes but interpreted as text by the system clipboard
  API (macOS `pbcopy`). No binary MIME type support.
- Requires a running daemon on the client machine.
- Not applicable to a browser-based client like MobiSSH.

Sources:
- [github.com/wincent/clipper](https://github.com/wincent/clipper)

### pbcopy/pbpaste over SSH port forwarding (macOS pattern, proven)

A common pattern on macOS is to run a `netcat` loop on the local machine that pipes incoming TCP
connections to `pbcopy`:

```bash
# On local Mac (listens for connections from remote)
while true; do nc -l 5556 | pbcopy; done

# SSH in with reverse tunnel
ssh -R 5556:localhost:5556 user@remote

# On remote, pipe text to local clipboard
echo "some text" | nc localhost 5556
```

Limitations:
- Text-only (`pbcopy` takes raw bytes interpreted as text).
- macOS only on the client side.
- Requires the local daemon before SSH connects.

Source:
- [Exposing Your Clipboard Over SSH](https://evolvingweb.com/blog/exposing-your-clipboard-over-ssh)
- [gist: forward clipboard via SSH reverse tunnels](https://gist.github.com/dergachev/8259104)

### xclip / xsel with X11 forwarding (proven on desktop, broken headless)

`xclip -selection clipboard -i` writes stdin to the X11 clipboard. With `ssh -X`, the X11
display is forwarded to the client. This allows a remote program to set the client's clipboard.

For image data:
```bash
xclip -selection clipboard -t image/png -i /tmp/paste.png
```

This is exactly what Claude Code uses on Linux to read clipboard images.

Limitations:
- Requires an X11 display server on the client side.
- In a headless Docker container (MobiSSH's production environment), `DISPLAY` is not set.
- X11 forwarding over SSH adds latency; requires `ssh -X` flag.
- Not applicable when the client is a mobile browser.

Sources:
- [ostechnix.com: xclip usage](https://ostechnix.com/access-clipboard-contents-using-xclip-and-xsel-in-linux/)

### wl-copy / wl-paste with Wayland (proven on Wayland desktop, N/A headless)

`wl-copy --type image/png < /tmp/paste.png` writes binary clipboard data on Wayland.

Limitations:
- Requires a running Wayland compositor. Not available in a headless Docker container.
- Socket forwarding exists but requires the Wayland socket path to be forwarded, which ssh2
  does not natively support.

Sources:
- [github.com/bugaevc/wl-clipboard](https://github.com/bugaevc/wl-clipboard)

### OSC 52 escape sequence (partially proven — text only, see Q2)

See Q2 for full analysis.

### xdotool (Linux desktop only, not useful for clipboard bridging)

`xdotool` simulates keyboard and mouse events. It can type text into the focused window but
does not provide a clipboard injection primitive for image data. Not applicable to headless
servers or the MobiSSH use case.

### VS Code Remote SSH clipboard (partial, text-focused)

VS Code Remote SSH does not natively forward clipboard for programmatic use. Paste into the
terminal is handled by the browser/client; copy out of the remote terminal requires mouse
selection. VS Code's devcontainer documentation suggests `socat` relays for container-to-host
clipboard forwarding, which is equivalent to the lemonade/clipper pattern (text only).

Source:
- [VS Code Remote Dev Tips](https://code.visualstudio.com/docs/remote/troubleshooting)
- [devcontainer clipboard forwarding](https://stuartleeks.com/posts/vscode-devcontainer-clipboard-forwarding/)

### JetBrains Gateway

JetBrains Gateway does forward clipboard bidirectionally between local and remote over its
proprietary binary protocol, including for IDE actions. However, this is a closed protocol
that requires the Gateway backend to run on the remote. Not applicable to MobiSSH.

---

## Q2: OSC 52 Deep Dive

### What is OSC 52?

OSC 52 is an ANSI/xterm escape sequence that allows a terminal application to write data to
the terminal emulator's system clipboard:

```
ESC ] 52 ; Pc ; Pd ST
```

- `Pc`: selection type (`c` = clipboard, `p` = primary, `q` = secondary, `s` = select)
- `Pd`: base64-encoded data to write, or `?` to query current clipboard contents

Example (write "hello" to clipboard):
```
printf '\033]52;c;aGVsbG8=\a'   # aGVsbG8= = base64("hello")
```

The terminal emulator intercepts this and calls its clipboard API. This allows remote programs
(over SSH) to set the local machine's clipboard without X11 forwarding, and without touching
the PTY in a user-visible way.

Sources:
- [xterm control sequences spec (XFree86)](https://www.xfree86.org/current/ctlseqs.html)
- [gpanders.com: State of the Terminal](https://gpanders.com/blog/state-of-the-terminal/)

### Does xterm.js support OSC 52?

**Yes, via `@xterm/addon-clipboard`.** This is the official addon (v0.2.0) that registers an
OSC 52 handler inside xterm.js. It uses `navigator.clipboard.writeText()` and
`navigator.clipboard.readText()` under the hood.

Key details from the source
([ClipboardAddon.ts](https://github.com/xtermjs/xterm.js/blob/master/addons/addon-clipboard/src/ClipboardAddon.ts)):

```ts
// Registers OSC 52 handler:
terminal.registerOscHandler(52, data => this._setOrReportClipboard(data));

// Uses text-only Clipboard API:
class BrowserClipboardProvider implements IClipboardProvider {
  readText(selection: ClipboardSelectionType): Promise<string> {
    return navigator.clipboard.readText();
  }
  writeText(selection: ClipboardSelectionType, data: string): Promise<void> {
    return navigator.clipboard.writeText(data);
  }
}
```

The addon also supports a custom `IClipboardProvider` interface, allowing interception of
clipboard reads and writes.

MobiSSH **does not currently load this addon** — it uses xterm.js without the clipboard addon.

Sources:
- [xterm.js addon-clipboard on npm](https://www.npmjs.com/package/@xterm/addon-clipboard)
- [xterm.js addon-clipboard source](https://github.com/xtermjs/xterm.js/tree/master/addons/addon-clipboard)
- [OSC 52 support request issue #3260](https://github.com/xtermjs/xterm.js/issues/3260)

### Can xterm.js intercept OSC 52 from the remote?

**Yes.** If MobiSSH loads `@xterm/addon-clipboard`, the addon intercepts any OSC 52 sequence
that the remote sends. By supplying a custom `IClipboardProvider`, MobiSSH can intercept the
`writeText` call and invoke `navigator.clipboard.write()` on the mobile device.

This gives a complete remote-to-mobile clipboard flow:
```
Remote process (e.g., tmux, neovim)
  -> sends OSC 52 escape sequence through PTY
  -> server receives from sshStream
  -> forwards via WebSocket to browser
  -> xterm.js OSC 52 handler fires
  -> custom IClipboardProvider.writeText() called
  -> navigator.clipboard.writeText() updates mobile clipboard
```

Note: This flow is for **text**, using the existing OSC 52 text data field. It does not address
image data because OSC 52's `Pd` field is defined as base64-encoded **text** in the spec.

### Is image data possible via OSC 52?

**No standard extension exists.** OSC 52 has no binary MIME type field. The spec defines `Pd`
as base64-encoded text data only. Several terminal emulators and tools (tmux, Neovim, WezTerm,
Kitty) implement OSC 52 as documented — text only.

A theoretical extension would be to embed PNG data in `Pd` along with a MIME type marker, but
no terminal emulator implements this, and no proposal exists in any RFC or spec.

### Can OSC 52 be sent in reverse (client → remote process)?

**No standard mechanism exists.** The spec defines OSC 52 as a sequence from the remote process
to the terminal emulator. The query form (`Pd = ?`) asks the emulator to respond with the
current clipboard contents, but many terminals disable this for security. The response would
be sent back as an OSC 52 sequence to the remote process's stdin — text only.

### Does Claude Code use OSC 52?

**No.** Claude Code reads the local clipboard directly via `xclip`/`wl-paste` (Linux) or
`osascript` (macOS). It does not emit OSC 52 sequences and does not listen for them.

---

## Q3: Lightweight Sidecar Approach

A sidecar is a small service running on the remote server that:
1. Listens on a Unix socket or localhost TCP port for incoming clipboard data.
2. Stores the data in memory (or a temp file).
3. When queried by a clipboard tool wrapper, returns the stored data.
4. Can be wrapped by a fake `xclip`/`wl-paste` that intercepts Claude Code's clipboard commands.

### How lemonade implements this

Lemonade's architecture (from [lemonade/server/clipboard.go](https://github.com/lemonade-command/lemonade/blob/master/server/clipboard.go)):
- The local machine runs `lemonade server` listening on TCP port 2489.
- The remote machine has `lemonade` installed; `lemonade copy` sends text to the TCP port.
- SSH `-R 2489:localhost:2489` makes the local machine's port 2489 appear at `localhost:2489`
  on the remote.

For MobiSSH, the equivalent would be:
- The MobiSSH bridge (Node.js) listens on a TCP port (e.g., 4892).
- The SSH connection uses reverse forwarding to expose that port on the remote as `localhost:4892`.
- A wrapper script on the remote named `xclip` checks for the forwarded port:
  ```bash
  #!/bin/bash
  # /usr/local/bin/xclip wrapper
  if curl -s http://localhost:4892/health > /dev/null 2>&1; then
    curl -s -X POST http://localhost:4892/clipboard --data-binary @-
  else
    /usr/bin/xclip.real "$@"
  fi
  ```
- Claude Code's `xclip -selection clipboard -t TARGETS -o` call hits the wrapper.
- The wrapper queries the MobiSSH bridge for the image, which returns the uploaded PNG.

This is theoretically sound but requires:
- Installing a wrapper script on the remote (or modifying `PATH`).
- The MobiSSH bridge to serve an HTTP endpoint on the forwarded port.
- The remote to have `curl` available.

The wrapper script approach is used by VS Code devcontainer clipboard forwarding and is
proven in production (sshboard, clippy projects).

Sources:
- [bvgastel/clippy](https://github.com/bvgastel/clippy)
- [bitpowder.eu: sshboard](https://www.bitpowder.eu/blog/shared-clipboard.page)

---

## Q4: SSH Channel Approach

### Can ssh2 open an exec channel alongside an active shell?

**Yes.** The SSH protocol (RFC 4254) supports multiple channels multiplexed over one connection.
`ssh2` (the Node.js library) allows calling `sshClient.exec()` while a `sshClient.shell()` PTY
is already open on the same connection.

From the ssh2 docs and community confirmation:
```
"It is OK to have more than one channel open simultaneously."
```

The exec channel is completely separate from the PTY shell channel. Writing to the exec channel's
stdin does not affect the shell's PTY; the terminal session continues uninterrupted.

### API for exec alongside shell

```js
// Active shell already running via sshClient.shell()
// Open a second exec channel:
sshClient.exec(
  'xclip -selection clipboard -t image/png -i /dev/stdin',
  { env: { DISPLAY: ':99' } },  // if Xvfb is running
  (err, stream) => {
    if (err) { /* fallback */ return; }
    stream.write(imageBuffer);  // pipe PNG data to xclip's stdin
    stream.end();
    stream.on('close', (code) => {
      if (code === 0) {
        // clipboard set successfully, safe to Ctrl+V
      }
    });
  }
);
```

This is the key insight: **the exec channel is a side channel, completely isolated from the PTY**.
The user's active terminal session is unaffected.

### Running xclip on a separate exec channel

The command:
```bash
xclip -selection clipboard -t image/png -i /dev/stdin
```

reads PNG data from stdin and places it in the X11 clipboard. By piping the image buffer through
the exec channel's stdin, MobiSSH can set the remote clipboard without touching the PTY.

**Requirement:** `xclip` still needs `DISPLAY` to be set. This is the same constraint as
before, but it now applies only to the exec channel environment, not the PTY session.

Sources:
- [github.com/mscdex/ssh2](https://github.com/mscdex/ssh2)
- [ssh2 issue #480: multiple commands](https://github.com/mscdex/ssh2/issues/480)
- [chilkat SSH docs: multiple channels](https://www.chilkatsoft.com/refdoc/nodejsSshRef.html)

---

## Q5: Reverse Forwarding Approach

### Does ssh2 support `tcpip-forward` (reverse tunnels)?

**Yes.** `sshClient.forwardIn(bindAddr, bindPort, callback)` sends a `tcpip-forward` global
request to the server. The server then listens on `bindPort` on its loopback interface and
tunnels any incoming connections back to the client.

```js
// In server/index.js, after sshClient ready:
sshClient.forwardIn('127.0.0.1', 4892, (err, port) => {
  if (err) return;  // fall back
  // remote server now has localhost:4892 forwarded to MobiSSH bridge
  sshClient.on('tcp connection', (info, accept, reject) => {
    const channel = accept();
    // handle incoming connection from remote
    // channel.read() gets request data
    // channel.write() sends clipboard content response
  });
});
```

The MobiSSH Node.js bridge would handle incoming TCP connections by serving clipboard data
(e.g., a simple HTTP or line-protocol handler for the uploaded image).

### Comparison: reverse forwarding vs. sidecar approach

| Aspect | Reverse port forwarding | Sidecar (wrapper script) |
|---|---|---|
| Requires install on remote | No (except `curl` or similar) | No (unless wrapping `xclip`) |
| Works without X11 | Yes (protocol level) | Depends on what wrapper calls |
| Image data flow | Remote `curl localhost:4892` → bridge serves PNG | Same |
| SSH channel interference | None | None |
| Requires DISPLAY for final step | Yes (if calling `xclip` from wrapper) | Yes |
| Complexity | Medium — bridge must handle TCP events | Medium — wrapper script needed |

Both approaches avoid PTY interference. The wrapper script approach is slightly simpler because
it piggybacks on Claude Code's existing `xclip` invocation pattern.

Sources:
- [ssh2 GitHub](https://github.com/mscdex/ssh2)
- [reverse-tunnel-ssh npm](https://www.npmjs.com/package/reverse-tunnel-ssh)

---

## Q6: What Does Claude Code Actually Need?

### Claude Code's clipboard image protocol (Linux)

From reverse-engineering reported in GitHub issues
([#29204](https://github.com/anthropics/claude-code/issues/29204),
[#25935](https://github.com/anthropics/claude-code/issues/25935),
[#14635](https://github.com/anthropics/claude-code/issues/14635)):

**Detection command (checks if image is in clipboard):**
```bash
xclip -selection clipboard -t TARGETS -o 2>/dev/null \
  | grep -E "image/(png|jpeg|jpg|gif|webp|bmp)"
# OR (Wayland):
wl-paste -l 2>/dev/null | grep -E "image/(png|jpeg|jpg|gif|webp|bmp)"
```

**Read image command:**
```bash
xclip -selection clipboard -t image/png -o
# OR (Wayland):
wl-paste --type image/png
```

Claude Code runs these as shell subprocesses when the user presses Ctrl+V. The output is
base64-encoded and passed to the model as image content.

**On macOS** (from earlier research doc — `docs/image-paste-research.md`):
```bash
osascript -e 'the clipboard as «class PNGf»'
```

### Environment variable override?

**No documented override exists.** Claude Code does not expose a `CLIPBOARD_COMMAND` or
`CLIPBOARD_TOOL` environment variable. The `xclip`/`wl-paste` invocations are hardcoded in
the Claude Code binary (`cli.js`).

### Can a wrapper script intercept the xclip call?

**Yes, via PATH manipulation.** If a directory containing a fake `xclip` appears before
`/usr/bin` in `$PATH`, Claude Code will invoke the wrapper instead of the real `xclip`. The
wrapper can:
1. Return a response from MobiSSH's clipboard bridge for read requests.
2. Pass through write requests to the real `xclip` (or ignore them).

This requires setting `PATH` in the shell environment before Claude Code starts, which can be
done via `.bashrc`, `.profile`, or by setting the SSH exec channel's environment.

Alternatively, the MobiSSH bridge can write the image directly to a temp file path and set that
as the X11 clipboard via the exec channel approach — no wrapper needed if `DISPLAY` is available.

### File path delivery (universal fallback)

From community reports ([Claude Code devcontainer workaround](https://shyamverma.com/claude-code-devcontainer-image-paste-workaround)):

> "Claude Code automatically attaches images when you provide their full path."

If the user types or pastes the path `/tmp/mobissh_paste.png` into the Claude Code prompt,
Claude Code will read and attach the image directly without needing the clipboard. This fallback
works on all servers (headless, no X11, no Wayland) and requires no additional tooling.

Sources:
- [anthropics/claude-code issue #29204](https://github.com/anthropics/claude-code/issues/29204)
- [anthropics/claude-code issue #14635](https://github.com/anthropics/claude-code/issues/14635)
- [blog.shukebeta.com: Claude Code image paste fix](https://blog.shukebeta.com/2025/07/11/quick-fix-claude-code-image-paste-in-linux-terminal/)

---

## Q7: Recommended Approach for MobiSSH

### Ranking of approaches

| Approach | Reliability | Headless? | Installs required | PTY safe? |
|---|---|---|---|---|
| SSH exec channel + xclip + Xvfb | High (proven tools) | Yes (with Xvfb) | xclip + xvfb (Docker) | ✅ |
| Reverse port forward + wrapper script | Medium (more moving parts) | Yes | curl (common) | ✅ |
| File path delivery (fallback) | High (always works) | ✅ | None | ✅ |
| OSC 52 (text only) | High (for text) | ✅ | None | ✅ |
| lemonade / clipper | Low (binary install) | No | lemonade binary | ✅ |
| xclip via PTY (rejected) | — | — | — | ❌ |

### Recommended: SSH exec channel with xclip (primary path)

**Architecture:**

```
Mobile clipboard (image/png)
  -> navigator.clipboard.read()           [MobiSSH frontend]
  -> read PNG blob -> base64-encode
  -> sendSftpUpload('/tmp/mobissh_paste_<ts>.png', base64)
                                          [existing SFTP upload -- no PTY touch]
  -> upload succeeds
  -> MobiSSH frontend sends new WS message: { type: 'clipboard_inject', path: '/tmp/...' }
  -> server/index.js receives
  -> sshClient.exec('xclip -selection clipboard -t image/png -i /tmp/mobissh_paste_<ts>.png',
                    { env: { DISPLAY: ':99' } })
                                          [separate SSH channel -- no PTY touch]
  -> exec channel completes (exit code 0 = success, non-0 = no X11)
  -> if success: send Ctrl+V (\x16) through sshStream (PTY) to trigger Claude Code paste
  -> if fail: toast path to user (fallback)
```

**Required components:**

| Component | Location | Change needed |
|---|---|---|
| Frontend clipboard detection | `src/modules/selection.ts` | Already planned in #227 |
| SFTP upload | `src/modules/connection.ts` / `server/index.js` | Already exists |
| `clipboard_inject` WS message | `server/index.js` | New: `sshClient.exec()` call |
| `xclip` | Docker container | Add to `apt-get install` in Dockerfile |
| `xvfb` | Docker container | Add to `apt-get install`; start with `Xvfb :99 &` |
| Ctrl+V delay | `server/index.js` or frontend | 500ms after exec completes |

**Why exec channel avoids PTY interference:**

The exec channel (`sshClient.exec()`) opens a new SSH channel (RFC 4254 §6.5). Data written to
its stdin goes to the process's stdin, completely separate from the PTY shell channel. The user's
active terminal session (shell, vim, Claude Code, etc.) receives no input and is not interrupted.

**Headless Docker:**

Add to `Dockerfile`:
```dockerfile
RUN apt-get install -y xclip xvfb
```

Add to container startup (entrypoint or `docker-compose.prod.yml`):
```bash
Xvfb :99 -screen 0 1x1x8 &
export DISPLAY=:99
```

The `1x1x8` screen size is minimal — a 1×1 pixel 8-bit display is sufficient for clipboard
operations; no actual rendering occurs.

**Fallback behavior:**

If the exec channel exits with non-zero (xclip not found, no DISPLAY), the server sends:
```json
{ "type": "clipboard_inject_result", "ok": false, "path": "/tmp/mobissh_paste_<ts>.png" }
```

The frontend toasts: `"Image uploaded to /tmp/mobissh_paste_<ts>.png"` — the user can type or
paste this path into their Claude Code prompt to attach the image.

**Data flow diagram:**

```
Mobile Browser              MobiSSH Bridge (Node.js)           Remote Server
     |                              |                                |
     |-- sftp_upload ------------->|                                |
     |   (base64 PNG)              |-- SFTP createWriteStream ----->|
     |                             |   /tmp/mobissh_paste_N.png     |
     |<-- sftp_upload_result ------|<-- SFTP finish ----------------|
     |   { ok: true }              |                                |
     |-- clipboard_inject -------->|                                |
     |   { path: '/tmp/...' }      |-- sshClient.exec() ----------->|
     |                             |   xclip -selection clipboard   |
     |                             |   -t image/png                 |
     |                             |   -i /tmp/mobissh_paste_N.png  |
     |                             |   (exec channel, not PTY)      |
     |                             |<-- exec close (code=0) --------|
     |<-- clipboard_inject_result--|                                |
     |   { ok: true }              |                                |
     |                             |-- sshStream.write('\x16') ---->|
     |                             |   (Ctrl+V to PTY, triggers     |
     |                             |    Claude Code paste)          |
     |-- toast "Image pasted" -----|                                |
```

### Alternative: OSC 52 for text clipboard (bonus, simpler)

For text clipboard (not images), MobiSSH could load `@xterm/addon-clipboard` with a custom
`IClipboardProvider` that bridges clipboard reads/writes over the WebSocket. This would enable
remote programs (tmux, neovim) to set the mobile clipboard via OSC 52 without any additional
server configuration. This is a separate enhancement from image paste and has no server-side
requirements.

### What does NOT work (headless, no X11/Wayland)

- `lemonade`, `clipper`, `pbcopy` over reverse tunnel: text only.
- `xclip` without `DISPLAY`: fails with `Error: Can't open display`.
- `wl-copy` without Wayland compositor: fails.
- OSC 52 for images: no spec, no implementation.

### Summary of recommended path

**For headless Docker (MobiSSH production):**
1. Add `xclip` and `xvfb` to the Dockerfile.
2. Start `Xvfb :99` in the container entrypoint.
3. MobiSSH bridge: after SFTP upload, open `sshClient.exec()` to run `xclip` with `DISPLAY=:99`.
4. After exec succeeds, send Ctrl+V through the PTY.
5. If exec fails, toast the file path as fallback.

**For arbitrary remote servers (no Xvfb):**
The fallback (toast file path) is the only guaranteed path. The Ctrl+V injection is skipped.
The user manually types `/tmp/mobissh_paste_<ts>.png` into Claude Code to attach the image.

This approach is:
- Zero-install on the remote for the fallback path.
- Low-install for the primary path (xclip + xvfb in the Docker image only).
- Safe: no PTY interference at any point.
- Proven: exec channels alongside shell sessions are supported by SSH protocol and ssh2 library.

Sources:
- [github.com/mscdex/ssh2](https://github.com/mscdex/ssh2)
- [anthropics/claude-code issue #29204](https://github.com/anthropics/claude-code/issues/29204)
- [github.com/lemonade-command/lemonade](https://github.com/lemonade-command/lemonade)
- [xterm.js addon-clipboard](https://github.com/xtermjs/xterm.js/tree/master/addons/addon-clipboard)
- [ArchWiki: Clipboard](https://wiki.archlinux.org/title/Clipboard)
