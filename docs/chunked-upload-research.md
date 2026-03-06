# Chunked SFTP Upload: Research Findings and Recommended Architecture

Research for issue #229: replacing the single-message `sftp_upload` with a chunked,
progress-reporting, cancellable, resumable upload protocol over the existing WebSocket.

## 1. Existing Libraries for Browser-to-WebSocket File Streaming

### socketio-file-upload (SIOFU)

**npm**: `socketio-file-upload` (~100 KiB default chunk size, Socket.IO-specific)

- Splits files into chunks (default 100 KiB), emits a `progress` event with `event.bytesLoaded / event.file.size`.
- Binary mode enabled by default since v0.3.2 (uses Socket.IO binary frames).
- No backpressure: chunks are dispatched without waiting for server acks.
- No retry/resume after disconnect.
- Socket.IO dependency means it cannot be dropped onto a plain `ws` server.
- **Verdict**: Not usable for MobiSSH (Socket.IO-specific, no backpressure, no resume).
- Source: https://www.npmjs.com/package/socketio-file-upload

### socket.io-stream

**npm**: `socket.io-stream`

- Lets you stream a `ReadableStream` from browser to a Socket.IO server. Progress tracked by listening to `data` events.
- Same constraint: requires Socket.IO on both sides.
- **Verdict**: Not applicable.
- Source: https://www.npmjs.com/package/socket.io-stream

### websocket-stream

**npm**: `websocket-stream`

- Wraps a WebSocket as a Node.js duplex stream on both the browser (via Browserify) and Node.js.
- Partial backpressure via `bufferedAmount` polling: exposes a `browserBufferSize` threshold and `browserBufferTimeout` interval to throttle writes.
- Does not handle acknowledgement-based flow control; no retry/resume.
- Last significant release was several years ago; maintenance status uncertain.
- **Verdict**: Provides a stream interface over WS but backpressure is poll-based (fragile on mobile). No progress or resume.
- Source: https://www.npmjs.com/package/websocket-stream

### ws-streamify

**npm**: `ws-streamify`

- Node.js only — not a browser library. Pipes Node.js streams over WebSocket with backpressure on the server side.
- Not relevant for the browser -> server direction.
- **Verdict**: Server-side only; not applicable.
- Source: https://github.com/baygeldin/ws-streamify

### streaming-iterables

**npm**: `streaming-iterables`

- Utility library for async iterables (not WebSocket-specific). Provides `pipeline`, `map`, `filter` etc. for async generators.
- Could be used to consume `File.stream()` as an async iterable and drive a chunk-sending loop, but adds no WebSocket integration, progress, or resume.
- **Verdict**: Generic utility; would require significant custom scaffolding on top.
- Source: https://www.npmjs.com/package/streaming-iterables

### uppy

**npm**: `uppy` (core) + plugins

- Uppy is a feature-rich file upload manager. Its companion server uses WebSockets to push progress events back to the browser client.
- Uppy itself uploads via HTTP (XHR/Fetch), not WebSocket. The WS channel is a progress/event bus only.
- Resumable uploads use the tus protocol (HTTP) or AWS S3 Multipart (HTTP). Neither maps to a plain-WS -> SFTP pipeline.
- Uppy's WS usage is proven at scale (Transloadit production), but the HTTP transport is non-negotiable.
- **Verdict**: Excellent for HTTP-based upload pipelines; does not fit a WS-only architecture.
- Source: https://uppy.io/docs/companion/

### FilePond

**npm**: `filepond`

- Chunked uploads via PATCH requests with `Upload-Offset` / `Upload-Length` headers (tus-compatible).
- Resume via HEAD request returning last `Upload-Offset`.
- No WebSocket transport mode; HTTP/XHR only.
- **Verdict**: Best-in-class for HTTP chunked uploads; not applicable to WS.
- Source: https://pqina.nl/filepond/docs/api/server

### simple-peer / webtorrent

- `simple-peer`: WebRTC peer-to-peer data channels (not server-mediated WebSocket).
- `webtorrent`: P2P streaming torrent (totally unrelated transport).
- **Verdict**: Neither applies to a browser -> WS server -> SFTP pipeline.

### Ecosystem gap conclusion

No npm library provides all of: browser-to-plain-WS chunked upload + ack-based backpressure + progress + retry/resume. The libraries that come closest either require Socket.IO (`socketio-file-upload`) or only handle the HTTP side (`uppy`, `filepond`). The correct approach is a custom protocol built on the primitives described below, drawing patterns from how these libraries solve each subproblem individually.

---

## 2. Browser Streams API

### File.stream() and ReadableStream

`File.prototype.stream()` returns a `ReadableStream<Uint8Array>`. Reading it yields chunks of the file without loading the whole file into memory first.

Browser support (as of 2026):
- `ReadableStream` / `WritableStream` / `TransformStream` / `pipeTo` / `pipeThrough`: universally supported in Chrome, Firefox, Safari 14.1+, and mobile equivalents.
- `File.stream()`: Chrome 76+, Firefox 69+, Safari 14.1+. Supported on mobile Chrome (Android) and Safari (iOS 14.5+).
- Sources: https://developer.mozilla.org/en-US/docs/Web/API/File, https://caniuse.com/mdn-api_file_stream

### WebSocketStream (experimental)

`WebSocketStream` is a Chrome-only experimental API (Origin Trial / Chromium only as of 2026) that integrates WebSocket natively with the Streams API, providing true automatic backpressure without polling. It is not supported in Safari/iOS and is not in Firefox. Its status is tracked at https://chromestatus.com/feature/5189728691290112.

Since MobiSSH must support both Android Chrome and iOS Safari, `WebSocketStream` cannot be used as the primary transport.

### WritableStream with a WebSocket sink

Piping `file.stream().pipeTo(writableWsSink)` is a documented pattern where a custom `WritableStream` calls `ws.send()` on each chunk. Backpressure in this model depends on whether the writer's `write()` method returns a Promise that resolves only after the server acks the chunk — a technique called **ack-gated flow control** (see section 6).

### Recommendation

Use `File.stream()` with a manual async reader loop (not `pipeTo`) to retain explicit control over chunk timing and ack gating:

```js
const reader = file.stream().getReader();
while (true) {
  const { done, value } = await reader.read();
  if (done) break;
  await sendChunkAndWaitForAck(value);
}
```

This is widely compatible (iOS 14.5+, all modern Android) and gives natural backpressure through the awaited ack.

---

## 3. Binary WebSocket Frames vs. Base64 JSON

### Overhead comparison

Base64 encoding inflates payload size by **~33%**. For a 3 MB file:
- Base64 in JSON: ~4 MB of data transmitted
- Raw binary frames: ~3 MB

WebSocket framing overhead itself is minimal: **2–14 bytes per frame** vs. 500–800 bytes of HTTP metadata per request. Source: https://hpbn.co/websocket/

### Memory and CPU cost

Text frames must contain valid UTF-8 and are validated by the protocol layer. Binary frames skip this check. When sending many frames at high frequency, repeated UTF-8 conversion and garbage collection pressure are measurable; binary frames keep memory usage roughly 2.5× lower in sustained-transfer benchmarks. Source: https://groups.google.com/g/nwjs-general/c/IB6EEMnWgVY

### ws npm binary support

`ws@8.x` (MobiSSH's current server library) fully supports sending and receiving `Buffer` and `ArrayBuffer` natively. The browser `WebSocket.send()` method accepts `ArrayBuffer` and `Blob` for binary frames. Both sides handle binary without additional libraries.

### The multiplexing problem

MobiSSH uses a single WebSocket for both SSH terminal input/output and SFTP control messages (JSON). Binary frames cannot carry a requestId or message type in their header without a custom framing layer. The options are:

1. **Keep all messages JSON** (base64 chunk data): simple, no framing code needed. 33% size overhead for file data only.
2. **Binary frames with custom framing**: prepend a small fixed-size header (e.g., 16-byte requestId + 4-byte offset) before the binary payload. Requires framing/deframing code on both sides. Eliminates the 33% base64 overhead.
3. **Separate WebSocket connection for binary data**: adds complexity and a second connection.

### Recommendation

For MobiSSH's single-WS architecture: **keep chunk data as base64 in JSON messages**. The 33% overhead on file data is acceptable (a 3 MB screenshot becomes ~4 MB of wire data), the implementation is simpler, and it avoids a custom binary framing layer on an already-shared WebSocket. If performance becomes a concern at larger file sizes, option 2 (custom binary framing) can be added without changing the rest of the protocol.

---

## 4. Progress Reporting Patterns

### Two models: sent-based vs. acked-based

**Sent-based progress** (`bufferedAmount` polling):
- After calling `ws.send(chunk)`, the browser's `WebSocket.bufferedAmount` reflects bytes queued but not yet transmitted. Progress ≈ `(bytesSent - ws.bufferedAmount) / totalBytes`.
- Limitation: reflects only the browser's send buffer, not server receipt, and definitely not SFTP write completion. On a fast LAN it can jump to 100% before the server has finished writing.
- `bufferedAmount` is broken in the Node.js `ws` library and should not be used server-side. On the browser it is reliable in Chrome/Firefox but behavior in iOS Safari is inconsistent.
- Source: https://developer.mozilla.org/en-US/docs/Web/API/WebSocket/bufferedAmount

**Acked-based progress** (server confirmation):
- Server sends `sftp_upload_ack` after each chunk is accepted. Client progress = `lastAckedOffset / totalSize`.
- True end-to-end progress reflecting actual data received by the server.
- Used by tus, FilePond, and S3 multipart (all use server-confirmed offsets).
- Granularity = 1 event per chunk (e.g., every 192 KiB = every ~0.5–2% for a 10–40 MB file).

### Recommendation

Use **acked-based progress** as the authoritative metric. Display percentage as `lastAckedOffset / file.size * 100`. Optionally, compute a finer-grained "sent" estimate by tracking `ws.send()` calls for smoother UI animation, but always reconcile against the last acked offset.

Resolution achievable: per-chunk (every 192 KiB). For a 3 MB file with 16 chunks, that is approximately 6% per update — suitable for a mobile progress bar.

---

## 5. Retry and Resume Patterns

### How existing libraries handle disconnect

- **tus protocol**: Each upload session has a unique URL. On reconnect the client sends a HEAD request; the server responds with `Upload-Offset`. The client resumes from that offset. File identity uses a fingerprint (combination of file name + size + lastModified). Source: https://tus.io/protocols/resumable-upload
- **FilePond**: Same pattern as tus (HEAD request + `Upload-Offset`).
- **Socket.IO v4.7+ connection state recovery**: The server buffers events for reconnecting clients for a configurable window. On reconnect Socket.IO replays missed events automatically. Source: https://socket.io/docs/v4/connection-state-recovery

### Fingerprinting uploads for resume

A lightweight fingerprint sufficient for MobiSSH: `${file.name}:${file.size}:${file.lastModified}`. For higher collision resistance, compute a SHA-256 of the first 64 KiB using `SubtleCrypto.digest()` (available in all modern browsers including iOS Safari 13+).

### Server-side offset tracking

The server keeps an in-memory map of `requestId -> { writeStream, bytesWritten }`. On disconnect, the map entry stays alive for a short TTL (e.g., 30 s). On reconnect, the client sends `sftp_upload_start` with the same `requestId` and fingerprint; if the server finds an existing entry it responds with the current `bytesWritten` offset so the client can skip already-delivered chunks.

If the write stream has already been closed (TTL expired), the server returns offset 0 and the client restarts.

### Chunk-level retry

Individual chunks should not be retried independently. If a chunk fails the WebSocket has likely disconnected; the whole-upload resume path handles this. Per-chunk timeouts add complexity for minimal gain.

### Reconnect backoff

Standard exponential backoff with jitter: initial 1 s, doubles to max 30 s, ±10% random jitter. The `reconnecting-websocket` npm package (https://github.com/pladaria/reconnecting-websocket) implements this pattern and is browser/Node compatible (3 kB gzipped). It does not add upload-specific logic — only the reconnect timing.

---

## 6. Backpressure

### The pipeline

```
File API -> ws.send() [browser buffer] -> ws receive [Node.js] -> sftp.createWriteStream() [SFTP stream] -> SSH2 channel -> remote SFTP server
```

Backpressure must be applied at two points:
1. **Browser → server**: stop calling `ws.send()` when the server cannot keep up.
2. **Server → SFTP stream**: stop reading from the WebSocket when `sftp.createWriteStream()` signals backpressure.

### Point 1: Browser → server (ack-gated flow control)

The browser WebSocket API has no native backpressure. `bufferedAmount` polling is the only browser-side mechanism, and it only reflects the browser's send buffer, not server processing capacity.

The proven solution is **ack-gated flow control**: send chunk N+1 only after receiving `sftp_upload_ack` for chunk N. This is the same pattern used by SSH's channel window (ssh2 already uses it internally for the underlying SSH connection). It naturally propagates backpressure from SFTP write speed all the way back to the browser's sending loop.

Optionally, allow a **window** of W in-flight chunks (e.g., W=2) to keep the pipeline busy across one round-trip. This is analogous to TCP's congestion window. Start with W=1 for simplicity.

### Point 2: Server → SFTP stream (ws drain)

In Node.js `ws@8.x`, `ws.send(data, callback)` invokes the callback when the data has been flushed to the OS. For the receive direction, the server must pause reading WebSocket messages when `sftp.createWriteStream().write()` returns `false` (backpressure from the SFTP stream), and resume on the SFTP stream's `drain` event.

Concretely: the server's `message` handler for `sftp_upload_chunk` should check the return value of `ws.write(buf)`. If it returns `false`, set a flag and defer sending `sftp_upload_ack` until the SFTP stream's `drain` fires. The client, receiving no ack, naturally stalls (because of point 1 above).

This ties the two backpressure points together: a slow SFTP write → delayed ack → browser stops sending → no unbounded buffering in Node.js memory.

### Does ws support backpressure natively?

The `ws` library exposes a `drain` event on the underlying `net.Socket` (`ws._socket`). When `ws.send()` returns before the OS buffer has drained, waiting for `ws._socket.once('drain', ...)` is the correct pattern. Source: https://github.com/websockets/ws/issues/1218

For the receive side: `ws.pause()` / `ws.resume()` on the WebSocket object itself is not exposed; instead, backpressure is applied by delaying the ack (point 1 above) rather than suspending the socket.

---

## 7. ssh2 SFTP Streaming Capabilities

MobiSSH uses `ssh2@^1.15.0` (mscdex/ssh2). The SFTP subsystem exposes a `SFTPWrapper` with `createWriteStream()`.

### API

```js
sftp.createWriteStream(remotePath, {
  flags: 'w',      // 'w' = create/truncate, 'r+' = modify in place
  encoding: null,  // binary (Buffer)
  mode: 0o644,
  autoClose: true,
  start: 0,        // byte offset to begin writing at
})
```

Source: https://github.com/mscdex/ssh2-streams/blob/master/SFTPStream.md

### Backpressure

`createWriteStream()` returns a standard Node.js `Writable`. The `write(chunk)` method returns `false` when the internal buffer is full; the `drain` event fires when it is safe to write again. This is standard Node.js stream backpressure and works correctly with `ssh2`.

### Piping

You can pipe any Node.js `Readable` directly:

```js
const ws = sftp.createWriteStream('/remote/path');
nodeReadable.pipe(ws);
ws.on('finish', () => { /* done */ });
ws.on('error', (err) => { /* handle */ });
```

For the chunked WebSocket protocol, individual Buffer chunks are written manually with `ws.write(buf)` rather than piping, so that each chunk write can be ack-gated.

### Seeking / Resume

The `start` option allows writing at a byte offset, enabling resume from the last acked offset:

```js
sftp.createWriteStream(remotePath, { flags: 'r+', start: lastAckedOffset })
```

Use `flags: 'r+'` when resuming an existing partial file (append to existing bytes from `start` onward). Use `flags: 'w'` for new or truncated files.

### Default chunk size

`ssh2` internally sends SFTP WRITE packets up to 32 KiB per SSH channel write (the SSH2 maximum packet size). The `createWriteStream()` interface bufgets chunks on top of this; no special tuning is needed for chunk sizes in the 64–256 KiB range.

### fastPut vs createWriteStream

`sftp.fastPut()` uses parallel SSH channel windows for higher throughput on large files. However, it does not support streaming from an in-memory buffer or resuming from an offset. For the chunked WS protocol, `createWriteStream()` is the correct API; `fastPut` is not applicable.

### Cancel / unlink

```js
ws.destroy();
sftp.unlink(remotePath, (err) => { /* cleanup partial file */ });
```

Destroying the write stream does not automatically delete the file; `unlink` must be called explicitly.

---

## 8. Recommended Architecture for MobiSSH

### Summary verdict

No existing npm library covers the full browser -> WS -> SFTP upload pipeline with ack-based backpressure, per-chunk progress, cancel, and resume. The correct approach is a **custom ack-gated chunked upload protocol** built directly on the existing `ws` + `ssh2` stack, drawing patterns from tus (resume semantics), SIOFU (chunking model), and standard Node.js stream backpressure.

### Data flow

```
[Browser]
  File.stream().getReader()
    │
    ▼  read 192 KiB chunk (Uint8Array)
  btoa / base64url encode
    │
    ▼
  ws.send({ type: 'sftp_upload_chunk', requestId, offset, data: '<base64>' })
    │
    ▼  await ack (Promise resolved by incoming message handler)
  [loop: next chunk]

[Node.js server]
  ws 'message' event (JSON parse)
    │
    ▼  sftp_upload_chunk
  Buffer.from(msg.data, 'base64')
    │
    ▼
  sftpWriteStream.write(buf)  ← returns false if SFTP is slow
    │   if false → wait for 'drain'
    ▼
  send({ type: 'sftp_upload_ack', requestId, offset: newOffset })
    │
    ▼  (ack received by browser, browser sends next chunk)
```

### Message types (additions to existing protocol)

```
// Client → Server
{ type: 'sftp_upload_start',  requestId, path, size, fingerprint, resumeFrom? }
{ type: 'sftp_upload_chunk',  requestId, offset, data: '<base64>' }
{ type: 'sftp_upload_end',    requestId }
{ type: 'sftp_upload_cancel', requestId }

// Server → Client
{ type: 'sftp_upload_ack',    requestId, offset }   // ready for next chunk
{ type: 'sftp_upload_result', requestId, ok: true }
{ type: 'sftp_upload_result', requestId, ok: false, error: string }
```

### Chunk size

**192 KiB raw** (→ ~256 KiB base64), well under the 4 MiB `MAX_MESSAGE_SIZE`. Yields ~16 chunks for a 3 MB screenshot, ~52 chunks for a 10 MB file. Each chunk produces one progress update event.

### Encoding

Keep **base64 in JSON** for chunk data. Rationale: the existing WebSocket carries mixed JSON messages (SFTP control, SSH terminal data); adding binary framing just for file chunks requires a custom demultiplexer. The 33% overhead is acceptable: a 10 MB file transfers as ~13 MB, which at a typical Tailscale rate (50+ Mbps) adds < 0.5 s. Revisit with binary frames + requestId header if files regularly exceed ~50 MB.

### Progress reporting

```js
// Browser
function onAck(offset) {
  const pct = Math.round(offset / file.size * 100);
  updateProgressBar(pct);  // fires ~16 times for a 3 MB file
}
```

### Cancel

```js
// Browser
sendCancel(requestId);   // { type: 'sftp_upload_cancel', requestId }
// abort the read loop

// Server
const entry = openUploads.get(requestId);
if (entry) {
  entry.writeStream.destroy();
  sftp.unlink(entry.path, () => {});
  openUploads.delete(requestId);
}
```

### Resume after reconnect

```js
// Browser
const fingerprint = `${file.name}:${file.size}:${file.lastModified}`;
// On reconnect, re-send sftp_upload_start with same requestId + fingerprint
// Server returns sftp_upload_ack with current offset (bytes already written)
// Browser skips chunks with offset < ack.offset
```

Server keeps `openUploads` map alive for 30 s after WebSocket disconnect (use a `setTimeout` to clean up). If the browser reconnects within 30 s, it can resume seamlessly.

### Size validation

Validate on the client before calling `sftp_upload_start`:

```js
const MAX_UPLOAD_BYTES = 50 * 1024 * 1024; // 50 MB
if (file.size > MAX_UPLOAD_BYTES) {
  toast(`${file.name} is too large (max 50 MB)`);
  return;
}
```

### Cancel button in UI

Add a `<button class="files-cancel-btn">Cancel</button>` element next to the progress indicator in `_renderFilesPanel`. Show it when `_uploadActive === true`, hide it otherwise. On click, call `sendSftpUploadCancel(requestId)` and clear the upload state.

### Backpressure summary

| Stage | Mechanism |
|---|---|
| Browser → WS send buffer | Ack-gated: only send chunk N+1 after ack N |
| Node.js WS receive → SFTP write | Check `write()` return; delay ack until `drain` if false |
| SFTP write → remote server | ssh2 handles this internally via SSH channel window |

### Specific packages

No new npm packages are needed for the core protocol. Optionally:

- `reconnecting-websocket@4.4.0` (https://github.com/pladaria/reconnecting-websocket) for exponential backoff reconnect if MobiSSH's connection layer doesn't already handle this. 3 kB gzipped, zero dependencies, browser + Node compatible.

### Proven vs. speculative

**Proven patterns (used in production):**
- Ack-gated chunked upload over socket: used by every major SSH client for SCP/SFTP (mirrors ssh2's own channel window semantics). The ssh2 library uses per-packet ACKs at the protocol layer already.
- Base64 JSON for control messages + file data on a single WS: used by MobiSSH's existing `sftp_download` (which already base64-encodes file content in a JSON message).
- `createWriteStream` + `drain` backpressure: documented Node.js stream pattern; applied to ssh2 SFTP in multiple production deployments.
- Fingerprint + server offset for resume: tus.io protocol (production at Transloadit, used by Vimeo, Google, GitHub). Adapted here for WS without the HTTP layer.

**Speculative / untested in this specific stack:**
- 30-second TTL for keeping write streams alive across WS disconnect: reasonable but not benchmarked against ssh2's internal keepalive behavior. Test with a real SFTP server.
- `flags: 'r+' + start: offset` for stream resume: documented in ssh2-streams but community reports (https://github.com/mscdex/ssh2-streams/issues/145) show edge cases with new files; test thoroughly.
- Binary frames + custom requestId header on the same WS as SSH terminal: not tested; marked as future optimization only.

---

## References

- [socketio-file-upload npm](https://www.npmjs.com/package/socketio-file-upload)
- [socket.io-stream npm](https://www.npmjs.com/package/socket.io-stream)
- [websocket-stream npm](https://www.npmjs.com/package/websocket-stream)
- [ws-streamify (server-side backpressure)](https://github.com/baygeldin/ws-streamify)
- [WebSocketStream API (Chrome-only)](https://developer.chrome.com/docs/capabilities/web-apis/websocketstream)
- [WebSocketStream MDN](https://developer.mozilla.org/en-US/docs/Web/API/WebSocketStream)
- [File.stream() browser support (MDN)](https://developer.mozilla.org/en-US/docs/Web/API/File)
- [High Performance Browser Networking – WebSocket chapter](https://hpbn.co/websocket/)
- [WebSocket.bufferedAmount (MDN)](https://developer.mozilla.org/en-US/docs/Web/API/WebSocket/bufferedAmount)
- [Node.js backpressuring in streams](https://nodejs.org/en/learn/modules/backpressuring-in-streams)
- [ws backpressure / drain detection issue](https://github.com/websockets/ws/issues/1218)
- [ssh2-streams SFTPStream documentation](https://github.com/mscdex/ssh2-streams/blob/master/SFTPStream.md)
- [ssh2-sftp-client npm](https://www.npmjs.com/package/ssh2-sftp-client)
- [tus resumable upload protocol](https://tus.io/protocols/resumable-upload)
- [FilePond chunked upload docs](https://pqina.nl/filepond/docs/api/server)
- [uppy companion streaming uploads](https://uppy.io/docs/companion/)
- [reconnecting-websocket npm](https://github.com/pladaria/reconnecting-websocket)
- [Robust WebSocket reconnection with exponential backoff](https://dev.to/hexshift/robust-websocket-reconnection-strategies-in-javascript-with-exponential-backoff-40n1)
