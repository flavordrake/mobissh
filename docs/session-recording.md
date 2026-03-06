# Session Recording: Research Findings and Recommended Architecture

Research for issue #235, attached to recording download bug #234.

Goal: a session recording system serving two audiences from the same data — human replay
(time-lapse playback, seekable, speed-adjustable) and AI analysis (structured command/output
extraction, session summarization, pattern learning).

## 1. asciicast v2 Format

Source: https://docs.asciinema.org/manual/asciicast/v2/ and
https://github.com/asciinema/asciinema/blob/master/doc/asciicast-v2.md

### File structure

asciicast v2 is newline-delimited JSON (NDJSON). The first line is a header object; every
subsequent line is an event array.

### Header schema

Required fields:

| Field | Type | Description |
|---|---|---|
| `version` | integer (must be 2) | Format version. |
| `width` | integer | Terminal columns at session start. |
| `height` | integer | Terminal rows at session start. |

Optional fields:

| Field | Type | Description |
|---|---|---|
| `timestamp` | integer (Unix epoch) | Wall-clock time session started. |
| `duration` | float | Total recording length in seconds. |
| `idle_time_limit` | float | Cap on gaps between events (for playback speed). |
| `title` | string | Human-readable session label. |
| `command` | string | Shell command that was recorded. |
| `env` | object | Environment snapshot; standard keys are `SHELL` and `TERM`. |
| `theme` | object | Terminal colour theme; keys `fg`, `bg`, `palette`. |

No formal extension mechanism exists for custom header keys, but the spec says "unknown fields
MUST be ignored" by parsers. Custom keys like `"git_commit"`, `"profile"`, or `"session_id"` can
safely be added to the header. Players (asciinema-player, agg, etc.) will not fail; they will
silently skip the unknown keys.

### Event schema

Each event is a three-element JSON array: `[time, type, data]`.

| Position | Type | Description |
|---|---|---|
| `time` | float | Elapsed seconds since recording start (e.g., `3.141592`). |
| `type` | string | One-character event type (see below). |
| `data` | string | Event payload. |

Defined event types:

| Type | Name | Data format | Notes |
|---|---|---|---|
| `"o"` | output | Raw bytes written to the terminal (ANSI sequences included). | Most common type. |
| `"i"` | input | Raw bytes typed by the user. | Added in v2 but rarely captured by recording tools. |
| `"r"` | resize | Terminal dimensions as `"WxH"` (e.g., `"120x30"`). | |
| `"m"` | marker | Arbitrary label string (e.g., `"git commit abc1234"`). | Added in a v2 revision; documented at https://docs.asciinema.org/manual/asciicast/v2/#m-event |

The spec states: "Unknown event types MUST be skipped over by the players." Custom types beyond
the four above are therefore safely ignored by all compliant players. A custom `"x"` type
for application-level metadata annotations (git hashes, test results, file snapshots) is
well-suited to the spec's intent.

### MobiSSH current implementation gaps

`AsciicastHeader` in `src/modules/types.ts:201-207` does not include `duration`, `idle_time_limit`,
`env`, or `theme`. `AsciicastEvent` (line 209) is typed as `[number, 'o', string]`, which
hard-codes the output-only event type. Adding `'i'` and `'m'` to the union and extending
`AsciicastHeader` with optional fields requires only type changes plus the corresponding
data-capture logic.

---

## 2. Players: Comparison

### asciinema-player (JS embed)

- **npm**: `asciinema-player`
- **License**: Apache-2.0. Source: https://github.com/asciinema/asciinema-player/blob/main/LICENSE
- **Bundle size**: ~200 KB JS + ~10 KB CSS (gzipped) for v3.x. Source: https://bundlephobia.com/package/asciinema-player
- **Features**:
  - Seeking via click-to-seek on the progress bar.
  - Speed control: 0.25×, 0.5×, 1×, 2×, 4× (configurable range).
  - Auto-play and loop options.
  - Fit modes: `width` (expands to container), `height`, `both`, `none`.
  - Poster option: freeze-frame preview before play.
  - Copy-paste support (selectable terminal text while paused).
  - No built-in search/find function.
- **PWA compatibility**: yes. It is a standard ES module + CSS bundle with no server-side
  rendering requirement. Import via `import AsciinemaPlayer from 'asciinema-player'` and load
  a `.cast` file from a URL or inline string. Works with IndexedDB/OPFS-stored recordings by
  converting to a Blob URL.
- **Playback source**: `.cast` file URL, raw text content, or a custom driver object for
  streaming playback. Source: https://docs.asciinema.org/manual/player/
- **Verdict**: Best fit for in-app embedding. Apache-2.0 is compatible with MobiSSH's use.

### svg-term-cli (static SVG)

- **npm**: `svg-term-cli`
- **License**: MIT. Source: https://github.com/marionebl/svg-term-cli/blob/master/license
- **Output**: animated SVG (CSS `@keyframes`). Embeds directly in Markdown, HTML, or any SVG
  context without a JavaScript runtime.
- **Limitations**: no seeking, no speed control, no interaction. Purely for static sharing
  (README files, documentation, reports).
- **Bundle**: CLI tool only — not embeddable as a JS library. Generate the SVG at export time
  and distribute the static file.
- **Verdict**: Useful for exporting shareable session previews (e.g., alongside issue reports)
  but not for in-app replay.

### asciinema play (CLI)

- **License**: GPL-3.0 (asciinema Python package). Source: https://github.com/asciinema/asciinema/blob/master/LICENSE
- **Usage**: `asciinema play session.cast -s 2 -i 0.5` (2× speed, 0.5 s idle cap).
  Replays directly in the user's terminal.
- **Limitations**: not embeddable in a web app. Requires Python and asciinema installed locally.
  GPL-3.0 is incompatible with closed or proprietary embedding.
- **Verdict**: for power users who want to replay in their own terminal. Not suitable for in-app
  use.

### Recommendation

Embed **asciinema-player** (Apache-2.0) in a new "Recordings" tab for in-app human replay.
Export **svg-term-cli** (MIT) output as an optional "share as SVG" action for documentation.
`asciinema play` is an out-of-app tool, not a deployment target for MobiSSH.

---

## 3. Input Capture

### Hook point

`sendSSHInput()` in `src/modules/connection.ts:378-381` is the **single synchronous choke point**
for all terminal input:

```typescript
export function sendSSHInput(data: string): void {
  if (!appState.sshConnected || !appState.ws || appState.ws.readyState !== WebSocket.OPEN) return;
  appState.ws.send(JSON.stringify({ type: 'input', data }));
}
```

All keyboard paths — xterm.js key events, IME textarea, Ctrl+key combos, OSC 52 clipboard
paste, and `initialCommand` dispatch — route through this function before reaching the SSH
stream. Adding an input event to the recording buffer mirrors exactly what `connection.ts:156-158`
already does for output events:

```typescript
if (appState.recording && appState.recordingStartTime !== null) {
  appState.recordingEvents.push([(Date.now() - appState.recordingStartTime) / 1000, 'o', msg.data]);
}
```

An equivalent `"i"` push in `sendSSHInput()` would capture all input. No other hook points are
needed.

### Interleaved vs. separate streams

asciicast v2 is designed for interleaved events: every event carries its own elapsed timestamp,
so input and output are naturally ordered by causality. Keeping them in one stream preserves
the correlation "this output appeared N milliseconds after this input", which is valuable for
AI command-response extraction. Separate tracks would require a join on timestamps to reconstruct
causality and would complicate standard player compatibility.

**Recommendation**: use a single interleaved stream.

### Sensitive input redaction

Recording input events creates a risk of capturing passwords, passphrases, and API tokens typed
in response to terminal prompts.

Proposed strategy: track a `_inputSensitive: boolean` flag in the recording module.

1. On each output event, scan the trailing bytes of the data string for known password prompt
   patterns before storing the event:
   - `/[Pp]assword[^:]*:\s*$/`
   - `/[Pp]assphrase[^:]*:\s*$/`
   - `/\[sudo\] password/`
   - `/Enter passphrase/`
2. When a prompt matches, set `_inputSensitive = true`.
3. In `sendSSHInput()`, if `_inputSensitive` is true: store `[elapsed, "i", "[REDACTED]"]`
   (preserve timing, drop the actual content). Clear `_inputSensitive` after the first input
   event that contains `\r` or `\n` (i.e., after the user presses Enter to submit the password).

Storing `[REDACTED]` rather than omitting the event entirely preserves the timing shape of the
session (AI analysis can detect the presence of an authentication event without seeing the secret).

[INFERRED: prompt detection via regex is best-effort. Custom PAM modules, `read -s`, or prompts
embedded in application UI may not match these patterns. A per-profile "always-redact next input"
setting would provide a manual fallback. This needs user-facing design before implementation.]

---

## 4. Storage Options

### File size estimates

Terminal output throughput by activity level (source: asciicast file corpus analysis referenced
at https://github.com/asciinema/asciinema/issues/291 and practical measurements from
https://invisible-island.net/xterm/ctlseqs/ctlseqs.html):

| Activity | Raw throughput |
|---|---|
| Idle / reading | ~200–500 bytes/s |
| Typical interactive coding | ~2–5 KB/s |
| Heavy (compilation, test output) | ~10–50 KB/s peak |

asciicast v2 JSON wrapping overhead per event: `[{timestamp}, "o", "{data}"]` + newline.
With timestamps like `3.141592` (8 chars), type (3 chars), surrounding punctuation (~10 chars),
total overhead ≈ 20–30 bytes per event. Events typically arrive at 10–30 per second for
interactive sessions, adding ~0.3–0.7 KB/s of structural overhead.

**4-hour session estimates** (14,400 seconds):

| Activity | Raw data | With asciicast overhead | Compressed (gzip ~4:1 on JSON) |
|---|---|---|---|
| Light (500 B/s) | 7.2 MB | ~9 MB | ~2.3 MB |
| Typical (3 KB/s) | 43 MB | ~53 MB | ~13 MB |
| Heavy (15 KB/s) | 216 MB | ~270 MB | ~68 MB |

A typical active 4-hour coding session will produce a **50–70 MB** uncompressed `.cast` file.

### Client-side: IndexedDB / OPFS

**IndexedDB**:
- Storage quota: up to ~60% of available device storage in Chrome (origin-based, evictable under
  storage pressure). No hard byte cap. Source: https://web.dev/articles/storage-for-the-web
- Persistence: durable across browser restarts, but NOT immune to "clear site data" operations.
  In Chrome, marked as `"persistent"` if the user has installed the PWA — installed PWAs are
  granted durable storage. Source: https://developer.mozilla.org/en-US/docs/Web/API/StorageManager/persist
- Offline access: yes, fully available.
- Append performance: IndexedDB does not have an append API. Storing recording events requires
  either (a) one IndexedDB record per event (very high write amplification) or (b) periodic
  bulk writes of accumulated buffer chunks. Neither maps cleanly to a streaming-append model.

**OPFS (Origin Private File System)**:
- Same quota as IndexedDB. Source: https://developer.mozilla.org/en-US/docs/Web/API/File_System_API/Origin_private_file_system
- `FileSystemSyncAccessHandle.write()`: synchronous, only available inside a Web Worker.
  Designed for high-frequency append operations — this is the ideal API for streaming recording.
  Source: https://developer.mozilla.org/en-US/docs/Web/API/FileSystemSyncAccessHandle
- Browser support: Chrome 102+, Safari 15.2+, Firefox 111+.
  Source: https://caniuse.com/native-filesystem-api
- Persistence: survives app and browser restart; vulnerable to "clear all site data."
- Gap on WS disconnect: if the WebSocket drops, client-side recording continues to buffer events
  locally. No gap in the recording. This is the main advantage over server-side recording.

### Server-side: SFTP append

MobiSSH's existing SFTP operations (`sftp_ls`, `sftp_download`, `sftp_upload`) are discrete,
one-shot operations. Server-side streaming recording would require a new protocol:

1. On `startRecording()`, open an SFTP write stream on the remote server with `flags: 'a'`
   (append). Source: https://github.com/mscdex/ssh2-streams/blob/master/SFTPStream.md
2. Transmit each asciicast event JSON line to the server via a new `sftp_append` message type.
3. Server writes the line to the open write stream.

This approach has two distinct sub-variants:

- **Client-driven**: the client sends each event over the existing WebSocket → server writes
  to SFTP. Bandwidth: 2–50 KB/s additional WS traffic (same order as raw throughput estimates
  above). Gap on WS disconnect: all events generated while the WebSocket is down are lost.
- **Server-driven**: the server intercepts its own `data` events from the SSH shell channel and
  writes them to SFTP in parallel. No client involvement; no gap on WS disconnect. Requires
  server-side code changes to capture output at the bridge layer rather than at the client.
  [INFERRED: server-driven recording significantly changes the server's architecture — the server
  currently streams data straight to the WebSocket client and does not buffer it. This needs a
  design review before committing to it.]

Availability to remote tools and agents: recordings stored on the SFTP server are immediately
accessible to any tool that can SSH to the remote host (`cat session.cast`, `asciinema play`,
AI agent file access).

### Hybrid: client buffer + periodic SFTP flush

Client accumulates events in an OPFS file. A flush loop runs every N seconds (e.g., 30 s) or
every M events (e.g., 500), reading the unflushed tail and sending it to the server via the
`sftp_append` protocol.

On WS disconnect:
- OPFS continues accumulating locally (no gap).
- Flush loop detects the disconnect and pauses.
- On reconnect, the flush loop resumes from the last server-acknowledged offset.

On client session close (tab closed, browser crash):
- OPFS retains everything written since the last flush.
- On next session open, a "resume pending recording" check can flush the remainder.

This model provides: no recording gaps, offline-capable, server-accessible after first flush,
recoverable after client crash.

### Comparison table

| Dimension | Client (OPFS) | Server (SFTP) | Hybrid |
|---|---|---|---|
| WS disconnect gap | None | Client-driven: full gap. Server-driven: none. | None |
| Offline access | Yes | No | Yes (locally) |
| Remote tool access | No | Yes | Yes (after flush) |
| Client crash recovery | Yes (OPFS durable) | No (lost if not flushed) | Partial (last flush) |
| Implementation complexity | Low | High (server changes) | Medium |
| Bandwidth overhead | None | 2–50 KB/s | 2–50 KB/s (periodic) |
| Storage risk | Browser clear-data | Remote disk full | Both |

**Recommendation**: hybrid with OPFS primary and periodic SFTP flush. Rationale: it eliminates
recording gaps (the client-driven server variant's critical flaw), provides offline access,
and makes recordings available to remote tools without requiring server-side architectural
changes beyond a new `sftp_append` protocol. Start with OPFS-only for the first iteration
and layer in SFTP flush as a per-profile setting.

---

## 5. AI Consumption

### Token count problem

A raw 1-hour active session at 3 KB/s generates ~10.8 MB of terminal output. At the
OpenAI/Anthropic tokenization heuristic of ~4 characters per token, that is approximately
**2.7 million tokens** — far beyond any current context window and prohibitively expensive.
Strip ANSI codes first (reducing output by ~30–50%) and the estimate is still 1.4–1.9 million
tokens for one hour.

Direct LLM ingestion of raw asciicast is not viable. Preprocessing is required.

### Preprocessing pipeline

**Stage 1: ANSI stripping**

Remove all terminal control sequences (colors, cursor movements, screen clears). The `strip-ansi`
npm package (MIT, https://github.com/chalk/strip-ansi) applies the `ansi-regex` pattern
(also MIT, https://github.com/chalk/ansi-regex) and handles the full set of VT100/xterm escape
sequences. For a more accurate result (handling cursor positioning and overwrites), replay the
full stream through a headless terminal emulator (Stage 2).

**Stage 2: Terminal state reconstruction (optional, higher fidelity)**

xterm.js ships a headless mode for Node.js (`@xterm/xterm` — MIT, https://github.com/xtermjs/xterm.js)
and an add-on `@xterm/addon-serialize` (MIT) that serializes the current screen buffer to plain
text. Replaying the asciicast output events through a headless xterm.js instance and calling
`serialize()` periodically produces accurate plain-text snapshots free of overwritten or deleted
content. This is the same technique used by `agg` (asciinema GIF generator, MIT,
https://github.com/asciinema/agg) internally.

**Stage 3: Command extraction**

Detect shell prompts in the plain-text output stream and segment it into
`(prompt → command → output)` tuples. Common prompt patterns:

- `$ ` or `# ` at line start (POSIX sh, bash default)
- `user@host:path$ ` (bash with `PS1`)
- `❯ ` (zsh with popular themes)
- `(venv) $ ` (Python virtualenv)

A regex approach is fragile for non-standard prompts. A more reliable technique is to interleave
input (`"i"`) events with the output stream: each `"i"` event that contains `\r` or `\n`
(Enter keypress) marks the end of a command line. The output after that event until the next
input Enter is the command's output. This works regardless of the visual prompt format.

No production-ready npm library for terminal-to-structured-data conversion was found as of
March 2026. The closest prior art:
- `pyte` (Python, LGPL-3.0, https://github.com/selectel/pyte): a full VT100/xterm terminal
  emulator for Python, used by `termtosvg` internally. Not usable directly in a Node.js pipeline.
- `termtosvg` (Python, BSD, https://github.com/nbedos/termtosvg): renders `.cast` to SVG via
  `pyte`. The internal session-to-text extraction logic is not exposed as a library API.
- Academic literature: "TermSuite" (https://hal.archives-ouvertes.fr/hal-01804193) proposes
  terminal session analysis for HCI research but does not target LLM consumption.

[INFERRED: building the command-extraction pipeline in-house using xterm.js headless + input event
correlation is the most viable path given the lack of production-ready tools. This is well-scoped
but non-trivial.]

**Stage 4: Session transcript format**

Output a structured transcript suitable for LLM context:

```
# Session: user@host (2026-03-06T14:22:00Z)
# Duration: 47 minutes
# Terminal: 220×50

[0:00:01] $ git status
On branch main
nothing to commit, working tree clean

[0:00:04] $ vim src/modules/recording.ts
# (editor session, 3m 22s, output suppressed — 847 lines)

[0:03:26] $ npm test
PASS src/modules/recording.test.ts (12 tests)

[0:03:41] $ git add -A && git commit -m "feat: add input capture"
[main abc1234] feat: add input capture
 1 file changed, 8 insertions(+), 2 deletions(-)
```

Editor sessions (vim, nano, emacs) produce dense ANSI output that is not useful as plain text.
Detecting them (by command name or by high ANSI-to-text ratio) and replacing with a summary
annotation reduces token count significantly.

**Token count after preprocessing (estimates)**

| Stage | Output size (1-hour session) | Token estimate |
|---|---|---|
| Raw asciicast | ~10.8 MB | ~2.7M |
| After ANSI strip | ~6 MB | ~1.5M |
| After terminal reconstruction | ~4 MB | ~1M |
| After command extraction only | ~500 KB | ~125K |
| After editor suppression + summarization | ~20–50 KB | ~5K–12K |

A fully preprocessed 1-hour coding session is within the context window of current frontier
models (100K–200K token context) at ~5K–12K tokens.

### Dual output recommendation

Store one recording, produce two artifacts:

1. **`.cast` file** (asciicast v2): the verbatim recording for human replay in asciinema-player.
2. **`.transcript.md`** file: preprocessed plain-text command log for AI consumption. Generated
   on demand (not at record time) to avoid blocking the recording loop.

The `.transcript.md` generation pipeline runs offline or server-side (not in the critical path
of the live session).

---

## 6. Existing `src/modules/recording.ts`: Current State and Gaps

### What it does today

`recording.ts` (as of commit f9b8aa5) implements:

- **Start/stop state**: `startRecording()` sets `appState.recording = true`, stores
  `Date.now()` as `appState.recordingStartTime`, and clears the event buffer
  (`appState.recordingEvents = []`).
- **Event buffer**: output events are accumulated in `appState.recordingEvents` as
  `[number, string, string][]` tuples. The actual push happens in `connection.ts:156-158`
  (inside the `case 'output':` handler), not in `recording.ts` itself.
- **Header construction**: `_downloadCastFile()` builds an `AsciicastHeader` with `version: 2`,
  terminal dimensions from `appState.terminal`, Unix timestamp, and a title derived from
  `currentProfile` (e.g., `user@host:22`).
- **Download**: the `.cast` file is assembled as NDJSON, wrapped in a `Blob`, and delivered via
  the Web Share API (`navigator.share`) with a fallback to `<a download>` for browsers that
  don't support file sharing. The file is named `mobissh-YYYY-MM-DDTHH-MM-SS.cast`.
- **UI**: start/stop buttons, recording indicator badge, and a live elapsed timer (`recTimer`).
- **Auto-save**: `connection.ts:169` calls `stopAndDownloadRecording()` on SSH disconnect,
  and `connection.ts:359` calls it on explicit disconnect.

### What is missing

| Gap | Detail |
|---|---|
| Input capture | `AsciicastEvent` is typed `[number, 'o', string]`. `sendSSHInput()` does not record `"i"` events. |
| Sensitive input redaction | No password-prompt detection or `[REDACTED]` substitution. |
| Metadata events | No `"m"` marker support. No facility to inject git hashes, test results, or timestamps mid-session. |
| Extended header fields | `AsciicastHeader` lacks `duration`, `idle_time_limit`, `env`, `theme`. |
| Streaming / persistent storage | All events are in `appState.recordingEvents` (in-memory array). A long session grows the array without bound; the entire contents are lost on tab close or crash. |
| Server-side storage | No SFTP write path for recordings. |
| OPFS write stream | No OPFS integration; could replace the in-memory array with a `FileSystemSyncAccessHandle` append stream in a Worker. |
| Playback | No in-app player. Download-only delivery. |
| Recording size display | The recording indicator shows elapsed time but not accumulated file size. |
| Per-profile auto-start | No profile-level recording preference. |

### What needs to change (for the recommended architecture)

1. **`src/modules/types.ts`**: extend `AsciicastEvent` to `[number, 'o' | 'i' | 'm', string]`;
   add optional fields to `AsciicastHeader`.
2. **`src/modules/recording.ts`**: add `recordInputEvent(data: string)` and
   `recordMarker(label: string)` functions; add password-prompt detection state.
3. **`src/modules/connection.ts`**: call `recordInputEvent()` in `sendSSHInput()`.
4. **New: recording worker**: a Web Worker that holds a `FileSystemSyncAccessHandle` to an OPFS
   file and accepts `postMessage({ type: 'append', line: string })` calls. Replaces the
   in-memory array for the streaming path.
5. **New: SFTP flush loop**: a periodic flush from the OPFS file tail to an SFTP append stream,
   implemented on top of a new `sftp_append` server message.

---

## 7. Privacy and Security

### Threat model

A recording contains everything that appeared on screen and everything typed. This includes:

- Passwords and passphrases entered at prompts.
- API tokens displayed in `cat`, `env`, shell expansions.
- Private keys displayed with `cat ~/.ssh/id_rsa`.
- Personal file paths, hostnames, and IP addresses.

### Controls

| Control | Mechanism |
|---|---|
| Per-profile opt-in | Recording is off by default. A profile-level boolean `"autoRecord": false` (default) prevents accidental recording of sensitive sessions. |
| Sensitive input redaction | Regex-based prompt detection before `"i"` event storage (see Section 3). |
| Encrypted client-side storage | OPFS files can be encrypted with the AES-GCM vault key already present in `appState.vaultKey`. Each chunk is encrypted before being written to `FileSystemSyncAccessHandle`. [INFERRED: this adds per-chunk encrypt/decrypt overhead in the Worker; measure impact on a mobile device before committing.] |
| No plaintext secrets in SFTP recordings | If a recording is flushed to SFTP, the same encrypted format should be used, or the flush path should be explicitly documented as "plaintext remote file — treat as sensitive." |
| Token pattern detection | Auto-detect and redact known token prefixes in output events: `ghp_`, `sk-`, `tskey-`, `xoxb-`, `AKIA`. Replace the match with `[TOKEN REDACTED]`. This is best-effort; novel token formats will not be caught. |
| Recording indicator | Always show the recording indicator badge while `appState.recording === true` so the user is never unaware that their session is being recorded. |

---

## 8. References

- [asciicast v2 spec](https://docs.asciinema.org/manual/asciicast/v2/)
- [asciinema GitHub source](https://github.com/asciinema/asciinema)
- [asciinema-player docs](https://docs.asciinema.org/manual/player/)
- [asciinema-player npm / license (Apache-2.0)](https://github.com/asciinema/asciinema-player/blob/main/LICENSE)
- [svg-term-cli (MIT)](https://github.com/marionebl/svg-term-cli)
- [agg (asciinema GIF generator, MIT)](https://github.com/asciinema/agg)
- [strip-ansi (MIT)](https://github.com/chalk/strip-ansi)
- [ansi-regex (MIT)](https://github.com/chalk/ansi-regex)
- [xterm.js headless / serialize add-on (MIT)](https://github.com/xtermjs/xterm.js)
- [pyte terminal emulator (Python, LGPL-3.0)](https://github.com/selectel/pyte)
- [termtosvg (Python, BSD)](https://github.com/nbedos/termtosvg)
- [File System Access API / OPFS (MDN)](https://developer.mozilla.org/en-US/docs/Web/API/File_System_API/Origin_private_file_system)
- [FileSystemSyncAccessHandle (MDN)](https://developer.mozilla.org/en-US/docs/Web/API/FileSystemSyncAccessHandle)
- [OPFS browser support (caniuse)](https://caniuse.com/native-filesystem-api)
- [Storage for the web (web.dev)](https://web.dev/articles/storage-for-the-web)
- [StorageManager.persist() (MDN)](https://developer.mozilla.org/en-US/docs/Web/API/StorageManager/persist)
- [ssh2-streams SFTPStream API](https://github.com/mscdex/ssh2-streams/blob/master/SFTPStream.md)
- [bundlephobia: asciinema-player](https://bundlephobia.com/package/asciinema-player)
