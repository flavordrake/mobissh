'use strict';

/**
 * MobiSSH PWA — WebSocket SSH Bridge + Static File Server
 *
 * Serves the PWA frontend on HTTP and the SSH bridge on WebSocket,
 * both on the same port so only one endpoint needs to be exposed.
 *
 * Protocol (JSON messages):
 *
 *   Client → Server:
 *     { type: 'connect', host, port, username, password? }
 *     { type: 'connect', host, port, username, privateKey? }
 *     { type: 'input', data: string }
 *     { type: 'resize', cols: number, rows: number }
 *     { type: 'disconnect' }
 *     { type: 'hostkey_response', accepted: boolean }
 *     // [SFTP_TYPES] -- keep in sync with handleSftpMessage and WS router
 *     { type: 'sftp_ls', path: string, requestId: string }
 *     { type: 'sftp_download', path: string, requestId: string }
 *     { type: 'sftp_upload', path: string, data: string, requestId: string }
 *     { type: 'sftp_upload_start', path: string, size: number, fingerprint: string, requestId: string }
 *     { type: 'sftp_upload_chunk', offset: number, data: string, requestId: string }
 *     { type: 'sftp_upload_end', requestId: string }
 *     { type: 'sftp_upload_cancel', requestId: string }
 *     { type: 'sftp_download_start', path: string, requestId: string }
 *     { type: 'sftp_stat', path: string, requestId: string }
 *     { type: 'sftp_rename', oldPath: string, newPath: string, requestId: string }
 *     { type: 'sftp_delete', path: string, requestId: string }
 *     { type: 'sftp_realpath', requestId: string }
 *
 *   Server → Client:
 *     { type: 'connected' }
 *     { type: 'output', data: string }
 *     { type: 'error', message: string }
 *     { type: 'disconnected', reason: string }
 *     { type: 'hostkey', host, port, keyType, fingerprint }
 *     // [SFTP_RESULTS] -- keep in sync with client types.ts ServerMessage
 *     { type: 'sftp_ls_result', requestId, entries: [{name, isDir, isSymlink, size, mtime, atime, permissions, uid, gid}] }
 *     { type: 'sftp_download_result', requestId, data: string }  (base64)
 *     { type: 'sftp_download_meta', requestId, size: number }
 *     { type: 'sftp_download_chunk', requestId, offset: number, data: string }  (base64, legacy)
 *     { type: 'sftp_download_chunk_bin', requestId, offset: number, size: number }  (binary frame follows)
 *     { type: 'sftp_download_end', requestId }
 *     { type: 'sftp_upload_ack', requestId, offset: number }
 *     { type: 'sftp_upload_result', requestId, ok: boolean, error?: string }
 *     { type: 'sftp_stat_result', requestId, stat: {isDir, size, mtime} }
 *     { type: 'sftp_rename_result', requestId, ok: true }
 *     { type: 'sftp_delete_result', requestId, ok: true }
 *     { type: 'sftp_realpath_result', requestId, path: string }
 *     { type: 'sftp_error', requestId, message: string }
 */

const http = require('http');
const fs = require('fs');
const path = require('path');
const dns = require('dns');
const { createHash, createHmac, randomBytes, timingSafeEqual } = require('crypto');
const { execSync } = require('child_process');
const WebSocket = require('ws');
const { Client } = require('ssh2');
const { isOriginAllowed } = require('./origin');
const TRACE_TRANSFER = process.env.MOBISSH_TRACE_TRANSFER === '1' || true; // default on for data gathering
const { rewriteManifest } = require('./manifest');

const PORT = process.env.PORT || 8081;
const HOST = process.env.HOST || '0.0.0.0';
// BASE_PATH: set when served behind a reverse-proxy at a subpath (e.g. /ssh).
// Must start with / and have no trailing slash.  Example: BASE_PATH=/ssh
const BASE_PATH = (process.env.BASE_PATH || '').replace(/\/$/, '');

const PUBLIC_DIR = path.resolve(__dirname, '..', 'public');

// ─── CSWSH prevention (issue #83) ─────────────────────────────────────────────
// WS_ORIGIN_ALLOWLIST: comma-separated list of additional allowed origins.
// Example: WS_ORIGIN_ALLOWLIST=https://myapp.tailnet.ts.net,https://localhost:8081

// Parse WS_ORIGIN_ALLOWLIST once at startup.
const WS_ORIGIN_ALLOWLIST = (process.env.WS_ORIGIN_ALLOWLIST || '')
  .split(',')
  .map(s => s.trim())
  .filter(Boolean);

// ─── WS upgrade authentication (issue #93) ────────────────────────────────────
// Per-boot secret — never stored, never logged, never leaves this process.
const SESSION_SECRET = randomBytes(32);
// Token expiry: 1 hour by default; covers normal sessions and auto-reconnects.
const WS_TOKEN_EXPIRY_MS = parseInt(process.env.WS_TOKEN_EXPIRY_MS || '') || 3_600_000;

/** Produces a `timestamp:nonce:hmac` token signed with SESSION_SECRET. */
function generateWsToken() {
  const ts = Date.now().toString();
  const nonce = randomBytes(16).toString('hex');
  const mac = createHmac('sha256', SESSION_SECRET).update(`${ts}:${nonce}`).digest('hex');
  return `${ts}:${nonce}:${mac}`;
}

/** Returns true iff the token is well-formed, unexpired, and HMAC-valid. */
function validateWsToken(token) {
  if (!token || typeof token !== 'string') return false;
  const parts = token.split(':');
  if (parts.length !== 3) return false;
  const [ts, nonce, mac] = parts;
  const tsNum = parseInt(ts, 10);
  if (isNaN(tsNum) || Date.now() - tsNum > WS_TOKEN_EXPIRY_MS) return false;
  const expected = createHmac('sha256', SESSION_SECRET).update(`${ts}:${nonce}`).digest('hex');
  const expectedBuf = Buffer.from(expected);
  const macBuf = Buffer.from(mac);
  if (expectedBuf.length !== macBuf.length) return false;
  return timingSafeEqual(expectedBuf, macBuf);
}

const APP_VERSION = require('./package.json').version || '0.0.0';
let GIT_HASH = 'unknown';
try { GIT_HASH = execSync('git rev-parse --short HEAD', { encoding: 'utf8' }).trim(); } catch (_) {
  // In Docker: no git, read baked hash from build
  try { GIT_HASH = fs.readFileSync(path.join(__dirname, '..', '.git-hash'), 'utf8').trim(); } catch (_2) {}
}

// Cache the install-hooks doc + canonical bridge script at startup for the
// /install-hooks routes. Doc is served as text/markdown; the script is served
// as text/plain so curl/wget/WebFetch can pipe it directly to a file.
let INSTALL_HOOKS_DOC = '';
let INSTALL_HOOKS_BRIDGE_SCRIPT = '';
try {
  INSTALL_HOOKS_BRIDGE_SCRIPT = fs.readFileSync(
    path.join(__dirname, '..', 'hooks', 'mobissh-bridge.sh'),
    'utf8',
  );
} catch (_) {
  INSTALL_HOOKS_BRIDGE_SCRIPT = '#!/usr/bin/env bash\n# install-hooks: mobissh-bridge.sh not bundled in this image\nexit 1\n';
}
try {
  INSTALL_HOOKS_DOC = fs.readFileSync(
    path.join(__dirname, '..', 'docs', 'install-mobissh-hooks.md'),
    'utf8',
  );
} catch (_) {
  INSTALL_HOOKS_DOC = '# install-mobissh-hooks.md not found\n\nThis MobiSSH build was packaged without the install doc.\n';
}

// SSE clients for real-time telemetry push
const sseClients = new Set();

// Pending approval gates: requestId → { status, decision, timer }
let _approvalCounter = 0;
const pendingApprovals = new Map();

// Default approval mode: 'allow' or 'deny'. Persisted to disk so it survives restarts.
const APPROVAL_MODE_FILE = path.join(__dirname, '..', '.approval-mode');
let _approvalDefaultMode = (() => {
  try { return fs.readFileSync(APPROVAL_MODE_FILE, 'utf8').trim() || 'allow'; }
  catch { return 'allow'; }
})();

/** Broadcast an SSE event to all connected clients. */
function sseBroadcast(event, data) {
  const msg = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
  for (const client of sseClients) {
    client.write(msg);
  }
}

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js':   'application/javascript; charset=utf-8',
  '.css':  'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.webmanifest': 'application/manifest+json',
  '.svg':  'image/svg+xml',
  '.png':  'image/png',
  '.ico':  'image/x-icon',
};

// ─── SFTP message handler (exported for unit tests) ──────────────────────────

// Module-level upload registry keyed by fingerprint so entries survive WS reconnect.
// Each entry: { stream, offset, path, fingerprint, requestId, sftp, ttlTimer }
const resumableUploads = new Map();

const UPLOAD_TTL_MS = 30_000; // 30s grace period after WS disconnect

/**
 * Dispatch a single SFTP message to the open sftp channel.
 * `send` is a function(obj) that sends a JSON message to the WS client.
 * All errors are returned as { type: 'sftp_error', requestId, message } so the
 * WebSocket connection is never terminated by an SFTP failure.
 */
function handleSftpMessage(msg, sftp, send, openUploads, ws, connectionId) {
  const { requestId, path: filePath } = msg;
  const sftpErr = (message) => send({ type: 'sftp_error', requestId, message });

  // [SFTP_HANDLER] -- add new sftp_* cases here AND in the WS router below
  switch (msg.type) {
    case 'sftp_ls':
      sftp.readdir(filePath, (err, list) => {
        if (err) { sftpErr(err.message); return; }
        const entries = list.map(f => ({
          name: f.filename,
          isDir: f.attrs.isDirectory(),
          isSymlink: f.attrs.isSymbolicLink(),
          size: f.attrs.size,
          mtime: f.attrs.mtime,
          atime: f.attrs.atime,
          permissions: f.attrs.mode,
          uid: f.attrs.uid,
          gid: f.attrs.gid,
        }));
        send({ type: 'sftp_ls_result', requestId, entries });
      });
      break;

    case 'sftp_download': {
      const chunks = [];
      const rs = sftp.createReadStream(filePath);
      rs.on('data', chunk => chunks.push(chunk));
      rs.on('end', () => {
        send({ type: 'sftp_download_result', requestId, data: Buffer.concat(chunks).toString('base64') });
      });
      rs.on('error', err => sftpErr(err.message));
      break;
    }

    case 'sftp_download_start': {
      sftp.stat(filePath, (err, stats) => {
        if (err) { sftpErr(err.message); return; }
        const rid6 = requestId ? String(requestId).slice(-6) : '------';
        console.log(`[sftp-download:${rid6}] start path=${filePath} size=${stats.size}`);
        send({ type: 'sftp_download_meta', requestId, size: stats.size });
        // 256KB chunks give a much better ratio of WS framing overhead to
        // payload than the ssh2 32KB default.
        const rs = sftp.createReadStream(filePath, { highWaterMark: 256 * 1024 });
        let offset = 0;
        // Backpressure threshold: only pause the SFTP stream when the WS
        // outbound buffer exceeds 8MB. That keeps the pipe full but caps
        // memory. Previously the stream was paused *per chunk* waiting on
        // ws.send's callback, which capped throughput at ~1 chunk per RTT.
        const WS_BUFFER_HIGH = 8 * 1024 * 1024;
        const WS_BUFFER_LOW = 2 * 1024 * 1024;

        rs.on('data', (chunk) => {
          const currentOffset = offset;
          offset += chunk.length;
          // Binary framing: JSON header + raw binary frame back-to-back.
          // Kills the ~33% base64 bloat and the atob() CPU cost on mobile.
          // Message order on a single WS is preserved, so the pairing is safe.
          send({ type: 'sftp_download_chunk_bin', requestId, offset: currentOffset, size: chunk.length });
          if (ws.readyState === WebSocket.OPEN) {
            ws.send(chunk);
          }
          if (ws.bufferedAmount > WS_BUFFER_HIGH) {
            rs.pause();
            const drain = () => {
              if (ws.readyState !== WebSocket.OPEN) return;
              if (ws.bufferedAmount < WS_BUFFER_LOW) {
                rs.resume();
              } else {
                setTimeout(drain, 40);
              }
            };
            drain();
          }
        });
        rs.on('end', () => {
          console.log(`[sftp-download:${rid6}] done path=${filePath} bytes=${offset}`);
          send({ type: 'sftp_download_end', requestId });
        });
        rs.on('error', (e) => {
          console.log(`[sftp-download:${rid6}] error: ${e.message}`);
          send({ type: 'sftp_download_result', requestId, ok: false, error: e.message });
        });
      });
      break;
    }

    case 'sftp_upload': {
      if (typeof msg.data !== 'string') { sftpErr('data must be a base64 string'); return; }
      const buf = Buffer.from(msg.data, 'base64');
      const ws = sftp.createWriteStream(filePath);
      ws.on('finish', () => { send({ type: 'sftp_upload_result', requestId, ok: true }); });
      ws.on('error', err => sftpErr(err.message));
      ws.end(buf);
      break;
    }

    case 'sftp_upload_start': {
      const fingerprint = msg.fingerprint || '';
      const rid6 = requestId ? String(requestId).slice(-6) : '------';
      // Check for a resumable entry from a previous connection
      const existing = fingerprint ? resumableUploads.get(fingerprint) : null;
      if (existing && existing.stream && !existing.stream.destroyed && existing.connectionId === connectionId) {
        // Clear TTL timer — client reconnected in time
        if (existing.ttlTimer) { clearTimeout(existing.ttlTimer); existing.ttlTimer = null; }
        // Re-register under the new requestId in the per-connection map
        openUploads.set(requestId, { stream: existing.stream, offset: existing.offset, path: existing.path });
        existing.requestId = requestId;
        console.log(`[sftp-upload:${rid6}] resume path=${filePath} offset=${existing.offset} size=${msg.size ?? '?'}`);
        send({ type: 'sftp_upload_ack', requestId, offset: existing.offset });
      } else {
        // No resumable entry (or TTL expired) — create fresh
        if (openUploads.has(requestId)) {
          console.log(`[sftp-upload:${rid6}] duplicate start rejected path=${filePath}`);
          sftpErr('Upload already in progress for this requestId');
          return;
        }
        const ws = sftp.createWriteStream(filePath);
        ws.on('error', err => {
          console.log(`[sftp-upload:${rid6}] stream error: ${err.message}`);
          openUploads.delete(requestId);
          if (fingerprint) resumableUploads.delete(fingerprint);
          sftpErr(err.message);
        });
        const entry = { stream: ws, offset: 0, path: filePath, fingerprint, requestId, sftp, ttlTimer: null, connectionId };
        openUploads.set(requestId, { stream: ws, offset: 0, path: filePath });
        if (fingerprint) resumableUploads.set(fingerprint, entry);
        console.log(`[sftp-upload:${rid6}] start path=${filePath} size=${msg.size ?? '?'}`);
        send({ type: 'sftp_upload_ack', requestId, offset: 0 });
      }
      break;
    }

    case 'sftp_upload_chunk': {
      const upload = openUploads.get(requestId);
      if (!upload) { sftpErr('No upload in progress for this requestId'); return; }
      if (typeof msg.data !== 'string') { sftpErr('data must be a base64 string'); return; }
      const tDecode = performance.now();
      const buf = Buffer.from(msg.data, 'base64');
      const decodeMs = performance.now() - tDecode;
      const tWrite = performance.now();
      const canContinue = upload.stream.write(buf);
      const writeMs = performance.now() - tWrite;
      upload.offset += buf.length;
      // Keep resumable entry offset in sync
      for (const [, re] of resumableUploads) {
        if (re.requestId === requestId) { re.offset = upload.offset; break; }
      }
      if (canContinue) {
        if (TRACE_TRANSFER) console.log(`[transfer:${requestId.slice(-6)}] srv chunk offset=${upload.offset} decode=${decodeMs.toFixed(0)}ms write=${writeMs.toFixed(0)}ms drain=no`);
        send({ type: 'sftp_upload_ack', requestId, offset: upload.offset });
      } else {
        const tDrain = performance.now();
        upload.stream.once('drain', () => {
          if (TRACE_TRANSFER) console.log(`[transfer:${requestId.slice(-6)}] srv chunk offset=${upload.offset} decode=${decodeMs.toFixed(0)}ms write=${writeMs.toFixed(0)}ms drain=${(performance.now() - tDrain).toFixed(0)}ms`);
          send({ type: 'sftp_upload_ack', requestId, offset: upload.offset });
        });
      }
      break;
    }

    case 'sftp_upload_end': {
      const rid6End = requestId ? String(requestId).slice(-6) : '------';
      const upload = openUploads.get(requestId);
      if (!upload) {
        console.log(`[sftp-upload:${rid6End}] end without open upload`);
        sftpErr('No upload in progress for this requestId');
        return;
      }
      openUploads.delete(requestId);
      // Clean up resumable entry
      for (const [fp, re] of resumableUploads) {
        if (re.requestId === requestId) { resumableUploads.delete(fp); break; }
      }
      upload.stream.end(() => {
        console.log(`[sftp-upload:${rid6End}] done path=${upload.path} bytes=${upload.offset}`);
        send({ type: 'sftp_upload_result', requestId, ok: true });
      });
      break;
    }

    case 'sftp_upload_cancel': {
      const upload = openUploads.get(requestId);
      if (!upload) { sftpErr('No upload in progress for this requestId'); return; }
      openUploads.delete(requestId);
      // Clean up resumable entry
      for (const [fp, re] of resumableUploads) {
        if (re.requestId === requestId) {
          if (re.ttlTimer) clearTimeout(re.ttlTimer);
          resumableUploads.delete(fp);
          break;
        }
      }
      upload.stream.destroy();
      sftp.unlink(upload.path, () => {
        send({ type: 'sftp_upload_result', requestId, ok: false, error: 'cancelled' });
      });
      break;
    }

    case 'sftp_stat':
      sftp.stat(filePath, (err, stats) => {
        if (err) { sftpErr(err.message); return; }
        send({ type: 'sftp_stat_result', requestId, stat: { isDir: stats.isDirectory(), size: stats.size, mtime: stats.mtime } });
      });
      break;

    case 'sftp_rename':
      sftp.rename(msg.oldPath, msg.newPath, (err) => {
        if (err) { sftpErr(err.message); return; }
        send({ type: 'sftp_rename_result', requestId, ok: true });
      });
      break;

    case 'sftp_realpath':
      sftp.realpath('.', (err, absPath) => {
        if (err) { sftpErr(err.message); return; }
        send({ type: 'sftp_realpath_result', requestId, path: absPath });
      });
      break;

    case 'sftp_delete':
      sftp.stat(filePath, (err, stats) => {
        if (err) { sftpErr(err.message); return; }
        if (stats.isDirectory()) {
          sftp.rmdir(filePath, (e) => {
            if (e) { sftpErr(e.message); return; }
            send({ type: 'sftp_delete_result', requestId, ok: true });
          });
        } else {
          sftp.unlink(filePath, (e) => {
            if (e) { sftpErr(e.message); return; }
            send({ type: 'sftp_delete_result', requestId, ok: true });
          });
        }
      });
      break;

    default:
      sftpErr(`Unknown SFTP message type: ${msg.type}`);
  }
}

// ─── HTTP server (static files) ───────────────────────────────────────────────

const server = http.createServer((req, res) => {
  // POST /api/approval-gate — register a pending approval.
  //
  // Two protocols supported on the same endpoint, distinguished by the
  // `hookVersion` query param so deployed-but-stale hook scripts don't
  // silently break:
  //
  //   v1 (no hookVersion or hookVersion=1): legacy synchronous gate.
  //     Server holds the response open until a decision arrives or 120s
  //     elapses, then returns {decision: "allow"|"deny"}. This matches
  //     what the old hook script (≤4f1bcb-era) reads via `.decision //
  //     "deny"`. Slower but bw-compat-correct for any deployed copy of
  //     the old hook out in the wild.
  //
  //   v2+ (hookVersion>=2): poll-based. Returns {requestId} immediately,
  //     hook polls /api/approval-poll?id=N for the decision. Avoids
  //     long-held connections that Tailscale + cell radios sometimes
  //     drop. The current repo hook (hooks/mobissh-bridge.sh) is v2.
  //
  // The bug this guards against: in 2026-04-09 we shipped v2 server-side
  // without bumping the hook version negotiation. Any host where the
  // hook hadn't been re-installed kept reading `.decision` from a
  // response that no longer had it, falling through to "deny" on every
  // call as soon as a phone (SSE client) was connected. Symptom: every
  // tool call denied even though the user was tapping Allow on the
  // phone — the deny had already gone out before the user's tap could
  // possibly reach the server. Found 2026-04-09 in trace
  // boot-splash-telemetry-210808 after a long debug session.
  if (req.method === 'POST' && req.url?.startsWith('/api/approval-gate')) {
    let body = '';
    const parsedUrl = new URL(req.url, 'http://localhost');
    const hookVersionRaw = parsedUrl.searchParams.get('hookVersion');
    const hookVersion = hookVersionRaw ? parseInt(hookVersionRaw, 10) : 1;
    const isV2 = !Number.isNaN(hookVersion) && hookVersion >= 2;

    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
      try {
        const data = JSON.parse(body);
        const requestId = String(++_approvalCounter);
        const toolName = data.tool_name || data.tool || '';
        const toolInput = data.tool_input || {};
        const command = toolInput.command || toolInput.file_path || '';
        const desc = toolInput.description || '';
        const label = desc || (command ? `${toolName}: ${command}` : toolName) || 'Approval required';

        console.log(`[approval-gate] #${requestId}: "${label}" (SSE clients: ${sseClients.size}, hookVersion: ${isV2 ? '2+' : '1'})`);

        // If no clients connected, use the default mode — don't block Claude Code.
        // This shape works for both v1 and v2 hooks because both read .decision.
        if (sseClients.size === 0) {
          console.log(`[approval-gate] #${requestId}: no clients → default ${_approvalDefaultMode}`);
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ requestId, decision: _approvalDefaultMode, auto: true }));
          return;
        }

        // Broadcast to SSE + WS so the phone shows the approval bar
        const approvalData = { ...data, requestId, label };
        sseBroadcast('approval', approvalData);
        // eslint-disable-next-line no-use-before-define -- wss defined below; this callback fires after server boot
        wss.clients.forEach((client) => {
          if (client.readyState === WebSocket.OPEN) {
            client.send(JSON.stringify({ type: 'approval_prompt', ...approvalData }));
          }
        });

        const timer = setTimeout(() => {
          if (pendingApprovals.has(requestId)) {
            console.log(`[approval-gate] #${requestId}: timeout → default ${_approvalDefaultMode}`);
            const entry = pendingApprovals.get(requestId);
            const v1Resolver = entry && entry.v1Resolve;
            pendingApprovals.set(requestId, { decision: _approvalDefaultMode, status: 'timeout' });
            if (v1Resolver) v1Resolver(_approvalDefaultMode);
            // Cleanup after grace period for final poll
            setTimeout(() => { pendingApprovals.delete(requestId); }, 15000);
          }
        }, 120000);

        if (isV2) {
          // v2: return requestId immediately, hook polls
          pendingApprovals.set(requestId, { status: 'pending', timer });
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ requestId }));
        } else {
          // v1: hold the response open until /api/approval-respond fires
          // (or the timer above hits the timeout). Store a resolver in the
          // pending entry so respond can wake us up.
          pendingApprovals.set(requestId, {
            status: 'pending',
            timer,
            v1Resolve: (decision) => {
              try {
                if (!res.writableEnded) {
                  res.writeHead(200, { 'Content-Type': 'application/json' });
                  res.end(JSON.stringify({ requestId, decision }));
                }
              } catch (writeErr) {
                console.log(`[approval-gate] #${requestId}: v1 write failed — ${writeErr instanceof Error ? writeErr.message : 'unknown'}`);
              }
            },
          });
          // If the client disconnects before we resolve, drop the resolver
          // so a later respond doesn't try to write to a closed socket.
          req.on('close', () => {
            const entry = pendingApprovals.get(requestId);
            if (entry && entry.v1Resolve) {
              entry.v1Resolve = null;
            }
          });
        }
      } catch {
        res.writeHead(400);
        res.end('{"error":"invalid json"}');
      }
    });
    return;
  }

  // GET /api/approval-poll?id=N — hook polls for decision
  if (req.method === 'GET' && req.url?.startsWith('/api/approval-poll')) {
    const url = new URL(req.url, 'http://localhost');
    const requestId = url.searchParams.get('id');
    const pending = requestId ? pendingApprovals.get(requestId) : null;
    if (!pending) {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ status: 'expired' }));
      return;
    }
    if (pending.status === 'pending') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ status: 'pending' }));
    } else {
      // Decision made — return it and clean up
      const decision = pending.decision || 'deny';
      pendingApprovals.delete(requestId);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ status: 'decided', decision }));
    }
    return;
  }

  // GET/POST /api/approval-mode — get or set the default approval mode.
  if (req.url === '/api/approval-mode') {
    if (req.method === 'GET') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ mode: _approvalDefaultMode }));
      return;
    }
    if (req.method === 'POST') {
      let body = '';
      req.on('data', (chunk) => { body += chunk; });
      req.on('end', () => {
        try {
          const { mode } = JSON.parse(body);
          if (mode === 'allow' || mode === 'deny') {
            _approvalDefaultMode = mode;
            try { fs.writeFileSync(APPROVAL_MODE_FILE, mode); } catch { /* best effort */ }
            console.log(`[approval-mode] set to: ${mode}`);
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ ok: true, mode }));
          } else {
            res.writeHead(400, { 'Content-Type': 'application/json' });
            res.end('{"error":"mode must be allow or deny"}');
          }
        } catch {
          res.writeHead(400);
          res.end('{"error":"invalid json"}');
        }
      });
      return;
    }
  }

  // POST /api/approval-respond — client sends user's decision for a pending gate.
  // For v2 hooks: stores the decision so the next poll picks it up.
  // For v1 hooks: also wakes the held HTTP response on /api/approval-gate.
  if (req.method === 'POST' && req.url === '/api/approval-respond') {
    let body = '';
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
      try {
        const { requestId, decision } = JSON.parse(body);
        const pending = pendingApprovals.get(String(requestId));
        if (!pending) {
          console.log(`[approval-respond] #${requestId}: no pending gate`);
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ ok: false, reason: 'no pending gate' }));
          return;
        }
        clearTimeout(pending.timer);
        const safeDecision = decision || 'deny';
        console.log(`[approval-gate] #${requestId}: user decided → ${safeDecision}`);
        // If a v1 hook is holding the gate response open, wake it now.
        // Capture the resolver before overwriting the entry.
        const v1Resolve = pending.v1Resolve;
        pendingApprovals.set(String(requestId), { decision: safeDecision, status: 'decided' });
        if (v1Resolve) v1Resolve(safeDecision);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true }));
      } catch {
        res.writeHead(400);
        res.end('{"error":"invalid json"}');
      }
    });
    return;
  }

  // POST /api/hook — broadcast hook events to WS + SSE clients
  if (req.method === 'POST' && (req.url === '/api/approval' || req.url === '/api/hook')) {
    let body = '';
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
      try {
        const data = JSON.parse(body);
        const event = data.event || 'unknown';
        console.log(`[hook] event="${event}" tool="${data.tool || ''}" detail="${data.detail || ''}" desc="${data.description || ''}"`);
        // Determine message type based on hook event
        const isApproval = event === 'PermissionRequest';
        const sseEvent = isApproval ? 'approval' : 'hook';
        console.log(`[hook] → SSE event="${sseEvent}" (isApproval=${isApproval}, clients=${sseClients.size})`);
        const wsType = event === 'PermissionRequest' ? 'approval_prompt' : 'hook_event';
        // Broadcast to SSE clients (primary channel — works without WS connection)
        sseBroadcast(sseEvent, data);
        // Broadcast to WS clients (legacy — for sessions already connected)
        // eslint-disable-next-line no-use-before-define -- wss defined below; this callback fires after server boot
        wss.clients.forEach((client) => {
          if (client.readyState === WebSocket.OPEN) {
            client.send(JSON.stringify({ type: wsType, ...data }));
          }
        });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end('{"ok":true}');
      } catch {
        res.writeHead(400);
        res.end('{"error":"invalid json"}');
      }
    });
    return;
  }

  // POST /api/drop-telemetry — auto-upload of connection-drop telemetry
  // (connect log + gesture log + metadata, no screenshot). Client fires this
  // on every recovery from a `reconnecting` state, throttled to 5min/device.
  // Lands in test-results/uploads/ alongside bug reports so the watcher
  // surfaces it the same way; distinguished by the filename prefix.
  if (req.method === 'POST' && req.url === '/api/drop-telemetry') {
    let body = '';
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
      try {
        const data = JSON.parse(body);
        const { kind, reason, sessionId, host, ts, userAgent, url, version, connectLog, gestureLog } = data;
        const stamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
        const reportDir = path.join(__dirname, '..', 'test-results', 'uploads');
        fs.mkdirSync(reportDir, { recursive: true });

        let connectLogFile = '';
        if (Array.isArray(connectLog) && connectLog.length > 0) {
          connectLogFile = `${stamp}-drop-telemetry.connect-log.json`;
          fs.writeFileSync(
            path.join(reportDir, connectLogFile),
            JSON.stringify(connectLog, null, 2),
          );
        }

        let gestureLogFile = '';
        if (Array.isArray(gestureLog) && gestureLog.length > 0) {
          gestureLogFile = `${stamp}-drop-telemetry.gesture-log.json`;
          fs.writeFileSync(
            path.join(reportDir, gestureLogFile),
            JSON.stringify(gestureLog, null, 2),
          );
        }

        const meta = {
          kind: kind || 'drop-recovery',
          reason: reason || '',
          sessionId: sessionId || '',
          host: host || '',
          ts: ts || Date.now(),
          stamp,
          userAgent: userAgent || '',
          url: url || '',
          version: version || '',
          connectLogFile,
          connectLogEventCount: Array.isArray(connectLog) ? connectLog.length : 0,
          gestureLogFile,
          gestureLogEventCount: Array.isArray(gestureLog) ? gestureLog.length : 0,
        };
        fs.writeFileSync(path.join(reportDir, `${stamp}-drop-telemetry.json`), JSON.stringify(meta, null, 2));
        console.log(`[drop-telemetry] ${stamp} reason="${meta.reason}" host="${meta.host}" connectEvents=${meta.connectLogEventCount} gestureEvents=${meta.gestureLogEventCount}`);
        sseBroadcast('drop-telemetry', { reason: meta.reason, host: meta.host, stamp });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true, stamp }));
      } catch (err) {
        console.error('[drop-telemetry] parse error:', err.message);
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end('{"error":"invalid json"}');
      }
    });
    return;
  }

  // POST /api/bug-report — receive screenshot + logs from client, save to disk.
  if (req.method === 'POST' && req.url === '/api/bug-report') {
    let body = '';
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
      try {
        const data = JSON.parse(body);
        const { screenshot, logs, title, userAgent, url, version, connectLog, gestureLog } = data;
        const ts = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
        const reportDir = path.join(__dirname, '..', 'test-results', 'uploads');
        fs.mkdirSync(reportDir, { recursive: true });

        // Save screenshot
        let screenshotFile = '';
        if (screenshot) {
          const imgData = screenshot.replace(/^data:image\/\w+;base64,/, '');
          screenshotFile = `${ts}-bug-report.png`;
          fs.writeFileSync(path.join(reportDir, screenshotFile), Buffer.from(imgData, 'base64'));
          console.log(`[bug-report] screenshot: ${screenshotFile}`);
        }

        // Save logs
        if (logs) {
          fs.writeFileSync(path.join(reportDir, `${ts}-bug-report.log`), logs);
          console.log(`[bug-report] logs: ${ts}-bug-report.log`);
        }

        // Save 24h connect log if attached (added with the diagnostics work
        // — every connect/reconnect/state-transition event for the past day)
        let connectLogFile = '';
        if (Array.isArray(connectLog) && connectLog.length > 0) {
          connectLogFile = `${ts}-bug-report.connect-log.json`;
          fs.writeFileSync(
            path.join(reportDir, connectLogFile),
            JSON.stringify(connectLog, null, 2),
          );
          console.log(`[bug-report] connect log: ${connectLogFile} (${connectLog.length} events)`);
        }

        // Save 24h gesture log if attached — every swipe / pinch / long-press
        // / drag-select. For "swipes stopped working" bug reports.
        let gestureLogFile = '';
        if (Array.isArray(gestureLog) && gestureLog.length > 0) {
          gestureLogFile = `${ts}-bug-report.gesture-log.json`;
          fs.writeFileSync(
            path.join(reportDir, gestureLogFile),
            JSON.stringify(gestureLog, null, 2),
          );
          console.log(`[bug-report] gesture log: ${gestureLogFile} (${gestureLog.length} events)`);
        }

        // Save metadata
        const meta = {
          title: title || `Bug report ${ts}`,
          version,
          url,
          userAgent,
          ts,
          screenshotFile,
          connectLogFile,
          connectLogEventCount: Array.isArray(connectLog) ? connectLog.length : 0,
          gestureLogFile,
          gestureLogEventCount: Array.isArray(gestureLog) ? gestureLog.length : 0,
        };
        fs.writeFileSync(path.join(reportDir, `${ts}-bug-report.json`), JSON.stringify(meta, null, 2));

        const reportTitle = title || `Bug report ${ts}`;
        console.log(`[bug-report] saved: "${reportTitle}"`);
        sseBroadcast('bug-report', { title: reportTitle, saved: true });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true, saved: true }));
      } catch (err) {
        console.error('[bug-report] parse error:', err.message);
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end('{"error":"invalid json"}');
      }
    });
    return;
  }

  // /install-hooks — install snippet for adding the MobiSSH notification
  // hook to a Claude Code instance. Markdown so it renders sanely in
  // browsers AND copies cleanly when fetched by another Claude Code agent.
  if (req.url === '/install-hooks' || req.url === '/install-hooks.md') {
    res.writeHead(200, {
      'Content-Type': 'text/markdown; charset=utf-8',
      'Cache-Control': 'no-store',
    });
    res.end(INSTALL_HOOKS_DOC);
    return;
  }

  // /install-hooks/mobissh-bridge.sh — canonical bridge script. The doc
  // tells agents to fetch this URL directly, so script changes flow
  // automatically without a doc rewrite.
  if (req.url === '/install-hooks/mobissh-bridge.sh') {
    res.writeHead(200, {
      'Content-Type': 'text/plain; charset=utf-8',
      'Cache-Control': 'no-store',
    });
    res.end(INSTALL_HOOKS_BRIDGE_SCRIPT);
    return;
  }

  // /version — lightweight JSON endpoint (kept for curl / scripted checks).
  if (req.url === '/version') {
    res.writeHead(200, {
      'Content-Type': 'application/json',
      'Cache-Control': 'no-store',
    });
    res.end(JSON.stringify({ version: APP_VERSION, hash: GIT_HASH }));
    return;
  }

  // /events — SSE channel for real-time client telemetry.
  // Sends server version on connect so clients detect staleness immediately
  // after a container restart (SSE auto-reconnects via EventSource).
  if (req.url === '/events') {
    res.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-store',
      'Connection': 'keep-alive',
      'X-Accel-Buffering': 'no',
    });
    // Send version immediately on connect
    res.write(`event: version\ndata: ${JSON.stringify({ version: APP_VERSION, hash: GIT_HASH, uptime: process.uptime() })}\n\n`);
    // Heartbeat every 30s to keep the connection alive through proxies
    const heartbeat = setInterval(() => {
      res.write(': heartbeat\n\n');
    }, 30000);
    // Track this client for broadcast
    sseClients.add(res);
    req.on('close', () => {
      clearInterval(heartbeat);
      sseClients.delete(res);
    });
    return;
  }

  // /clear — nuke SW cache + storage so mobile browsers get a fresh start.
  // Visit https://<host>/ssh/clear after a bad SW deploy.
  // Uses JS instead of Clear-Site-Data header (which hangs on some mobile browsers).
  if (req.url === '/clear') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
    res.end(`<!DOCTYPE html><html><head><meta name="viewport" content="width=device-width"></head>
<body><pre id="log">Clearing...</pre><script>
(async()=>{const l=document.getElementById('log');function log(m){l.textContent+=m+'\\n'}
try{const regs=await navigator.serviceWorker.getRegistrations();
for(const r of regs){await r.unregister();log('Unregistered SW: '+r.scope)}
}catch(e){log('SW: '+e.message)}
try{const keys=await caches.keys();
for(const k of keys){await caches.delete(k);log('Deleted cache: '+k)}
}catch(e){log('Cache: '+e.message)}
try{localStorage.clear();log('localStorage cleared')}catch(e){}
try{sessionStorage.clear();log('sessionStorage cleared')}catch(e){}
log('\\nDone. Redirecting...');setTimeout(()=>location.href='./',1500)})();
</script></body></html>`);
    return;
  }

  const rel = path.normalize(req.url.split('?')[0]).replace(/^(\.\.[/\\])+/, '');
  const filePath = path.join(PUBLIC_DIR, rel === '/' || rel === '' ? 'index.html' : rel);

  if (!filePath.startsWith(PUBLIC_DIR + path.sep) && filePath !== PUBLIC_DIR) {
    res.writeHead(403);
    res.end('Forbidden');
    return;
  }

  fs.readFile(filePath, (err, data) => {
    if (err) {
      res.writeHead(404);
      res.end('Not found');
      return;
    }
    const ext = path.extname(filePath).toLowerCase();
    if (ext === '.html') {
      let html = data.toString();
      // Inject version meta tag so the client can display build info.
      html = html.replace(
        '<head>',
        `<head><meta name="app-version" content="${APP_VERSION}:${GIT_HASH}">`
      );
      // Inject base path so the client knows the subpath without unsafe-inline CSP.
      if (BASE_PATH) {
        html = html.replace(
          '<head>',
          `<head><meta name="app-base-path" content="${BASE_PATH}">`
        );
      }
      // Inject a fresh per-page-load HMAC token for WS upgrade auth (#93).
      html = html.replace(
        '<head>',
        `<head><meta name="ws-token" content="${generateWsToken()}">`
      );
      data = Buffer.from(html);
    }
    // Rewrite manifest.json: always apply stable identity + subpath rewrites (#83).
    // Also accept ?name= query param to customise name/short_name for multi-install (#131).
    if (path.basename(filePath) === 'manifest.json') {
      try {
        const manifestUrl = new URL(req.url, 'http://localhost');
        const customName = manifestUrl.searchParams.get('name') || '';
        if (BASE_PATH || customName) {
          data = rewriteManifest(data, customName);
        }
      } catch (_) {}
    }
    res.writeHead(200, {
      'Content-Type': MIME[ext] || 'application/octet-stream',
      'Cache-Control': 'no-store',
      'Content-Security-Policy': [
        "default-src 'self'",
        "script-src 'self'",
        "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
        "font-src 'self' https://fonts.gstatic.com",
        "connect-src 'self' wss: ws:",
        "img-src 'self' data: blob:",
        // Allow blob: URLs for SFTP video/audio previews. Without this the
        // browser rejects <video src="blob:…"> with "Media load rejected by
        // URL safety check" even though the bytes are local.
        "media-src 'self' blob:",
        "worker-src 'self'",
        "frame-ancestors 'none'",
      ].join('; '),
    });
    res.end(data);
  });
});

// ─── WebSocket server (SSH bridge) ────────────────────────────────────────────

const MAX_MESSAGE_SIZE = 4 * 1024 * 1024;
const WS_PING_INTERVAL_MS = 25_000;

// ─── Rate limiting / concurrency guard (issue #92) ────────────────────────────
// Every SSH session uses 2 WS (main + keepalive worker), so 4 profiles = 8 WS
// baseline. Add a reconnect storm after a mobile network flap and the old
// caps (8 active / 10 in 10s) trip immediately, locking the user out with
// "Too many connections" closes that the client just retries into another
// reject.
const MAX_CONNS_PER_IP    = 40;       // max new connection attempts per window
const THROTTLE_WINDOW_MS  = 10_000;   // sliding window duration (ms)
const MAX_ACTIVE_PER_IP   = 32;       // max concurrent WS/SSH sessions per IP (multi-session + reconnect overlap + transfers)

// ip → { attempts: number, windowStart: number, active: number }
const connTracker = new Map();

// ── Detached SSH session hold (ssh-session-resume) ───────────────────────────
// When a phone WS dies mid-session (Android backgrounding / network flap),
// hold the SSH connection alive for a grace window. If the phone reconnects
// with `?reattach=<sessionId>` the bridge swaps the new WS into the existing
// SSH stream and flushes a ring buffer of output captured during the gap.
// Result: from sshd's view nothing happened; from the user's view the
// reconnect is near-instant (no SSH handshake, scrollback preserved).
const HOLD_GRACE_MS = 300_000;       // 5min: how long to keep SSH alive after WS drop
const HOLD_BUFFER_MAX = 256 * 1024;  // 256 KB ring buffer of captured output

// sessionId → { clientIP, sshClient, sshStream, sftpClient, sftpPending,
//               openUploads, _sshTarget, ringBuffer, ringBufferBytes,
//               ringOverflow, graceTimer, captureChunk }
const heldSessions = new Map();

/** Park a session for HOLD_GRACE_MS; capture stream output in a ring buffer.
 *  Caller is responsible for nulling out its own SSH refs after this returns
 *  so the closing-WS closure stops manipulating the SSH state. */
function holdSession(sessionId, state) {
  // Replace the active stream listeners with capture-into-buffer listeners.
  // The OLD listeners (which called send() over the now-dead WS) were attached
  // by the WS-connection closure; remove them all and install ours.
  state.sshStream.removeAllListeners('data');
  state.sshStream.stderr.removeAllListeners('data');
  state.sshStream.removeAllListeners('close');

  state.ringBuffer = [];
  state.ringBufferBytes = 0;
  state.ringOverflow = false;

  state.captureChunk = (chunk) => {
    const s = chunk.toString('utf8');
    state.ringBuffer.push(s);
    state.ringBufferBytes += s.length;
    while (state.ringBufferBytes > HOLD_BUFFER_MAX && state.ringBuffer.length > 1) {
      const evicted = state.ringBuffer.shift();
      state.ringBufferBytes -= evicted.length;
      state.ringOverflow = true;
    }
  };
  state.sshStream.on('data', state.captureChunk);
  state.sshStream.stderr.on('data', state.captureChunk);

  // If SSH dies during the hold window, evict from the registry and free state.
  state.sshStream.on('close', () => {
    if (heldSessions.get(sessionId) === state) {
      heldSessions.delete(sessionId);
      clearTimeout(state.graceTimer);
      try { state.sshClient.end(); } catch (_) {}
      console.log(`[ssh-bridge] Held session SSH stream closed before reattach: sessionId=${sessionId.slice(0,8)}`);
    }
  });

  // Grace timer — if no reattach within HOLD_GRACE_MS, tear down.
  state.graceTimer = setTimeout(() => {
    if (heldSessions.get(sessionId) === state) {
      heldSessions.delete(sessionId);
      try { state.sshStream.close(); } catch (_) {}
      try { state.sshClient.end(); } catch (_) {}
      console.log(`[ssh-bridge] Held session expired: sessionId=${sessionId.slice(0,8)} (${state._sshTarget})`);
    }
  }, HOLD_GRACE_MS);

  heldSessions.set(sessionId, state);
}

function getIP(req) {
  return req.headers['x-forwarded-for']?.split(',')[0]?.trim()
    || req.socket.remoteAddress
    || 'unknown';
}

const wss = new WebSocket.Server({
  server,
  maxPayload: MAX_MESSAGE_SIZE,
  verifyClient({ req }, callback) {
    // Origin check runs regardless of TS_SERVE mode (#83).
    const origin = req.headers['origin'];
    const host = req.headers['host'];
    if (!isOriginAllowed(origin, host, WS_ORIGIN_ALLOWLIST)) {
      console.warn(`[ssh-bridge] Rejected WS upgrade: Origin "${origin}" does not match Host "${host}"`);
      callback(false, 401, 'Forbidden origin');
      return;
    }

    // Skip WS token auth when behind tailscale serve (strips query params,
    // tailscale/tailscale#18651) or when explicitly disabled for local dev/testing.
    if (process.env.TS_SERVE === '1' || process.env.WS_SKIP_TOKEN_AUTH === '1') {
      callback(true);
      return;
    }
    const url = new URL(req.url, 'http://localhost');
    const token = url.searchParams.get('token');
    if (!validateWsToken(token)) {
      callback(false, 401, 'Unauthorized');
      return;
    }
    callback(true);
  },
});

// WebSocket-level ping/pong to keep idle connections alive through proxies/NAT.
// Allow missed pongs before terminating (#204). Mobile browsers in background
// throttle the main thread — pong responses may be delayed significantly.
// 6 missed × 25s = 150s grace period before terminating.
if (require.main === module) {
  const WS_MAX_MISSED_PONGS = 6;
  const wsPingInterval = setInterval(() => {
    wss.clients.forEach((client) => {
      if (client.readyState !== WebSocket.OPEN) return;
      if (client._pongPending) {
        client._missedPongs = (client._missedPongs || 0) + 1;
        console.log(`[keepalive] Client missed pong #${client._missedPongs}/${WS_MAX_MISSED_PONGS}`);
        if (client._missedPongs >= WS_MAX_MISSED_PONGS) {
          // Before terminating: check if any OTHER WS from the same IP is still responding.
          // The Worker keepalive opens a separate WS — if it's alive, the client is reachable
          // and the main WS pong is just delayed by Android throttling.
          const clientIP = client._clientIP;
          let siblingAlive = false;
          if (clientIP) {
            wss.clients.forEach((other) => {
              if (other !== client && other._clientIP === clientIP && other.readyState === WebSocket.OPEN && !other._pongPending) {
                siblingAlive = true;
              }
            });
          }
          if (siblingAlive) {
            console.log(`[keepalive] Client missed ${client._missedPongs} pongs but sibling WS from ${clientIP} is alive — keeping`);
            client._missedPongs = 0; // Reset — the client is reachable via sibling
          } else {
            console.log(`[keepalive] Terminating client after ${WS_MAX_MISSED_PONGS} missed pongs`);
            client.terminate();
          }
          return;
        }
      } else {
        if (client._missedPongs > 0) {
          console.log(`[keepalive] Client recovered after ${client._missedPongs} missed pong(s)`);
        }
        client._missedPongs = 0;
      }
      client._pongPending = true;
      client.ping();
    });
  }, WS_PING_INTERVAL_MS);

  // Periodically evict stale connTracker entries to prevent unbounded Map growth.
  // Only remove entries with no active sessions and an expired attempt window.
  const connSweepInterval = setInterval(() => {
    const now = Date.now();
    for (const [ip, track] of connTracker) {
      if (track.active === 0 && now - track.windowStart > THROTTLE_WINDOW_MS) {
        connTracker.delete(ip);
      }
    }
  }, 60_000);

  wss.on('close', () => {
    clearInterval(wsPingInterval);
    clearInterval(connSweepInterval);
  });
}

// ─── SSRF prevention (issue #6, #84) ─────────────────────────────────────────
// Blocks RFC-1918 private, loopback, link-local, and other reserved addresses.
// Clients may send allowPrivate:true to override (controlled by the danger zone
// setting in the frontend — only for users who explicitly opt in).
//
// isPrivateIp(ip) performs numeric CIDR matching on a resolved IP address.
// connect() resolves the hostname via dns.lookup() before calling sshClient.connect(),
// preventing DNS rebinding attacks where a public hostname resolves to a private IP.

/**
 * Returns true if the given resolved IPv4 address falls within the CGNAT range
 * 100.64.0.0/10 (used by Tailscale).
 */
function isCgnatIp(ip) {
  const s = ip.trim().toLowerCase();
  const parts = s.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
  if (!parts) return false;
  const a = parseInt(parts[1]);
  const b = parseInt(parts[2]);
  if (a > 255 || b > 255) return false;
  const n = (a << 24 >>> 0) + (b << 16);
  const mask = (~0 << (32 - 10)) >>> 0;
  return (n & mask) === (0x64400000 & mask);
}

/**
 * Returns true if the given resolved IP address falls within any private,
 * loopback, link-local, CGNAT, ULA, or unspecified range.
 *
 * Covers:
 *   IPv4: 0.0.0.0/8, 10/8, 100.64/10, 127/8, 169.254/16, 172.16/12, 192.168/16
 *   IPv6: ::, ::1, fc00::/7 (ULA), fe80::/10 (link-local)
 *   IPv4-mapped IPv6: ::ffff:x.x.x.x — unwrapped and re-checked as IPv4
 */
function isPrivateIp(ip) {
  const s = ip.trim().toLowerCase();

  // IPv4-mapped IPv6: ::ffff:x.x.x.x or ::ffff:aabb:ccdd
  const mapped = s.match(/^::ffff:(\d+\.\d+\.\d+\.\d+)$/);
  if (mapped) return isPrivateIp(mapped[1]);

  // IPv6 checks
  if (s === '::' || s === '::1') return true;
  // ULA fc00::/7 — first byte 0xfc or 0xfd (binary prefix 1111 110x)
  if (s.startsWith('fc') || s.startsWith('fd')) return true;
  // Link-local fe80::/10 — first 10 bits are 1111 1110 10
  if (s.startsWith('fe80:') || s.startsWith('fe8') || s.startsWith('fe9') ||
      s.startsWith('fea') || s.startsWith('feb')) return true;

  // IPv4: parse to 32-bit integer for CIDR comparisons
  const parts = s.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
  if (!parts) return false; // unknown format — don't block
  const a = parseInt(parts[1]);
  const b = parseInt(parts[2]);
  const c = parseInt(parts[3]);
  const d = parseInt(parts[4]);
  if (a > 255 || b > 255 || c > 255 || d > 255) return false;
  const n = (a << 24 >>> 0) + (b << 16) + (c << 8) + d;

  // Helper: check if n falls in prefix/bits
  function inCidr(base, bits) {
    const mask = bits === 0 ? 0 : (~0 << (32 - bits)) >>> 0;
    return (n & mask) === (base & mask);
  }

  if (inCidr(0x00000000, 8))   return true; // 0.0.0.0/8      unspecified
  if (inCidr(0x0a000000, 8))   return true; // 10.0.0.0/8     RFC-1918
  if (inCidr(0x64400000, 10))  return true; // 100.64.0.0/10  CGNAT
  if (inCidr(0x7f000000, 8))   return true; // 127.0.0.0/8    loopback
  if (inCidr(0xa9fe0000, 16))  return true; // 169.254.0.0/16 link-local
  if (inCidr(0xac100000, 12))  return true; // 172.16.0.0/12  RFC-1918
  if (inCidr(0xc0a80000, 16))  return true; // 192.168.0.0/16 RFC-1918

  return false;
}

wss.on('connection', (ws, req) => {
  ws.on('pong', () => { ws._pongPending = false; ws._missedPongs = 0; });

  const clientIP = getIP(req);
  const now = Date.now();

  // Initialise or retrieve the tracker entry for this IP.
  if (!connTracker.has(clientIP)) {
    connTracker.set(clientIP, { attempts: 0, windowStart: now, active: 0 });
  }
  const track = connTracker.get(clientIP);

  // Reset attempt counter when the window has expired.
  if (now - track.windowStart > THROTTLE_WINDOW_MS) {
    track.attempts = 0;
    track.windowStart = now;
  }
  track.attempts++;

  if (track.attempts > MAX_CONNS_PER_IP) {
    console.warn(`[ssh-bridge] Rate limited: ${clientIP} (${track.attempts} attempts in window)`);
    ws.close(1008, 'Rate limited');
    return;
  }

  if (track.active >= MAX_ACTIVE_PER_IP) {
    console.warn(`[ssh-bridge] Connection cap reached: ${clientIP} (${track.active} active)`);
    ws.close(1008, 'Too many connections');
    return;
  }

  track.active++;
  ws._clientIP = clientIP; // Store for sibling-alive check in keepalive
  const connectionId = randomBytes(16).toString('hex'); // unique per WS session
  let _sshTarget = '(not yet connecting)';
  console.log(`[ssh-bridge] WS connected: ${clientIP} cid=${connectionId.slice(0,8)} (active: ${track.active})`);

  let sshClient = null;
  let sshStream = null;
  let sftpClient = null;
  let sftpPending = null; // pending callbacks while SFTP channel is being opened
  let connecting = false;
  let pendingVerify = null; // hostVerifier callback waiting for client response (#5)
  let openUploads = new Map(); // requestId → { stream, offset, path } for chunked uploads
  let mySessionId = null; // server-assigned reattachable ID, sent to client on shell ready

  function send(obj) {
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify(obj));
    }
  }

  // ── Reattach path ────────────────────────────────────────────────────────
  // Phone reconnects after a brief drop; if the bridge is still holding the
  // SSH session for this clientIP, swap this fresh WS into the existing
  // stream and flush the captured output. No SSH handshake, no auth round-trip.
  try {
    const url = new URL(req.url || '/', 'http://localhost');
    const reattachId = url.searchParams.get('reattach');
    if (reattachId) {
      const held = heldSessions.get(reattachId);
      if (held && held.clientIP === clientIP) {
        // Atomically claim the held session
        heldSessions.delete(reattachId);
        clearTimeout(held.graceTimer);
        // Swap the held SSH state into this closure
        sshClient = held.sshClient;
        sshStream = held.sshStream;
        sftpClient = held.sftpClient;
        openUploads = held.openUploads;
        _sshTarget = held._sshTarget;
        mySessionId = reattachId;
        // Replace capture-into-buffer listeners with send-via-new-WS listeners
        sshStream.removeAllListeners('data');
        sshStream.stderr.removeAllListeners('data');
        sshStream.removeAllListeners('close');
        sshStream.on('data', (chunk) => { send({ type: 'output', data: chunk.toString('utf8') }); });
        sshStream.stderr.on('data', (chunk) => { send({ type: 'output', data: chunk.toString('utf8') }); });
        sshStream.on('close', () => { cleanup('SSH stream closed'); });
        send({ type: 'reattached', sessionId: mySessionId });
        // Flush ring buffer (output produced during the gap)
        if (held.ringOverflow) {
          send({ type: 'output', data: '\r\n\u001b[33m[mobissh: buffer overflow during gap — earlier output trimmed]\u001b[0m\r\n' });
        }
        for (const chunk of held.ringBuffer) {
          send({ type: 'output', data: chunk });
        }
        console.log(`[ssh-bridge] WS reattached: ${clientIP} cid=${connectionId.slice(0,8)} → ${_sshTarget} (sessionId=${mySessionId.slice(0,8)}, flushed ${held.ringBufferBytes}B${held.ringOverflow ? ' overflow' : ''})`);
      } else {
        // ID provided but no matching hold (expired, or wrong IP)
        send({ type: 'reattach_failed' });
        console.log(`[ssh-bridge] reattach_failed: ${clientIP} cid=${connectionId.slice(0,8)} reattachId=${reattachId.slice(0,8)} (held=${!!held}${held && held.clientIP !== clientIP ? ' ip-mismatch' : ''})`);
      }
    }
  } catch (err) {
    console.warn(`[ssh-bridge] reattach parse error: ${err.message}`);
  }

  /** Lazily open the SFTP subsystem on first use; reuse the same channel.
   *  Concurrent callers are queued so only one sshClient.sftp() is ever in flight. */
  function getSftp(callback) {
    if (sftpClient) { callback(null, sftpClient); return; }
    if (!sshClient) { callback(new Error('Not connected')); return; }
    if (sftpPending) { sftpPending.push(callback); return; }
    sftpPending = [callback];
    sshClient.sftp((err, sftp) => {
      const pending = sftpPending;
      sftpPending = null;
      if (err) { pending.forEach(cb => cb(err)); return; }
      sftpClient = sftp;
      pending.forEach(cb => cb(null, sftp));
    });
  }

  function cleanup(reason) {
    pendingVerify = null; // discard any pending host-key verification (#5)
    // Set TTL on in-progress chunked uploads instead of destroying immediately (#123).
    // If the client reconnects within UPLOAD_TTL_MS, it can resume from bytesWritten.
    for (const [rid, upload] of openUploads) {
      // Find the resumable entry for this upload
      let found = false;
      for (const [fp, re] of resumableUploads) {
        if (re.requestId === rid) {
          re.ttlTimer = setTimeout(() => {
            try { re.stream.destroy(); } catch (_) {}
            // Best-effort unlink of partial file via the stored sftp handle
            try { re.sftp.unlink(re.path, () => {}); } catch (_) {}
            resumableUploads.delete(fp);
          }, UPLOAD_TTL_MS);
          found = true;
          break;
        }
      }
      // If no resumable entry (e.g. no fingerprint), destroy immediately
      if (!found) {
        try { upload.stream.destroy(); } catch (_) {}
      }
    }
    openUploads.clear();
    if (sshStream) {
      try { sshStream.close(); } catch (_) {}
      sshStream = null;
    }
    sftpClient = null;   // closed with the SSH connection
    sftpPending = null;  // discard any pending SFTP open requests
    if (sshClient) {
      try { sshClient.end(); } catch (_) {}
      sshClient = null;
    }
    connecting = false;
    if (reason) {
      send({ type: 'disconnected', reason });
      console.log(`[ssh-bridge] Session ended (${clientIP} cid=${connectionId.slice(0,8)} → ${_sshTarget}): ${reason}`);
    }
  }

  function connect(cfg) {
    if (connecting || sshClient) {
      send({ type: 'error', message: 'Already connected or connecting' });
      return;
    }
    connecting = true;

    if (!cfg.host || !cfg.username) {
      send({ type: 'error', message: 'host and username are required' });
      connecting = false;
      return;
    }

    // Resolve hostname to IP first, then check against private ranges.
    // This prevents DNS rebinding: a public-looking hostname resolving to a
    // private IP would bypass a hostname-only string check.
    dns.lookup(cfg.host, (dnsErr, address) => {
      if (dnsErr) {
        send({ type: 'error', message: `DNS resolution failed: ${dnsErr.message}` });
        connecting = false;
        return;
      }
      // In Tailscale mode (TS_SERVE=1), exempt CGNAT (100.64.0.0/10) since
      // Tailscale node addresses live in that range — this is the primary
      // deployment target. All other private ranges remain blocked (#91).
      const isTailscaleMode = process.env.TS_SERVE === '1';
      const blockedPrivate = isPrivateIp(address) && !(isTailscaleMode && isCgnatIp(address));
      if (blockedPrivate && !cfg.allowPrivate) {
        send({ type: 'error', message: 'Connections to private/loopback addresses are blocked. Enable "Allow private addresses" in Settings → Danger Zone to override.' });
        connecting = false;
        return;
      }
      connectAfterDns(cfg, address);
    });
  }

  function connectAfterDns(cfg, resolvedIp) {
    _sshTarget = `${cfg.username}@${cfg.host}:${cfg.port || 22}`;
    console.log(`[ssh-bridge] SSH connecting: ${_sshTarget} (resolved: ${resolvedIp}) cid=${connectionId.slice(0,8)}`);
    // Capture locally so the 'ready' callback can't null-deref if cleanup()
    // sets the outer `sshClient = null` between handshake and ready (crash seen
    // in prod: "Cannot read properties of null (reading 'shell')").
    const client = new Client();
    sshClient = client;

    // Per-phase timing so the connect-log captures where slowness lives. SSH
    // readyTimeout is 30s — when handshakes legitimately take 10–25s the user
    // can't tell which stage stalled (TCP, KEX, auth, channel).
    const phaseT0 = performance.now();
    const sendPhase = (name) => {
      const ms = Math.round(performance.now() - phaseT0);
      try { send({ type: 'phase', name, ms }); } catch (_) {}
      console.log(`[ssh-bridge] phase=${name} ms=${ms} cid=${connectionId.slice(0,8)} → ${_sshTarget}`);
    };

    // Fail-fast for unreachable hosts. 30s readyTimeout below covers
    // legitimate slow handshakes (DERP relays, sleeping targets); this
    // shorter window catches dead paths (Tailscale-offline peer, etc.)
    // where TCP routes into the void and ssh2 never receives any data.
    // Trip on whichever of greeting/banner/handshake fires first — the
    // greeting event is optional in ssh2 (not all servers emit it), but
    // handshake fires reliably once KEX completes.
    //
    // 10s, not 5s: a 5s window killed cold direct-path Tailscale connects
    // that would have completed at 6-9s after a phone wake — the bridge
    // saw the whole 5-failure halt threshold burn through in ~30s and
    // sessions wedged. 10s gives genuine cold-path NAT-traversal room
    // while still cutting the previous 30s readyTimeout in third for
    // truly dead hosts (e.g., Tailscale-offline peer).
    let progressSeen = false;
    const unreachableTimer = setTimeout(() => {
      if (progressSeen || sshClient !== client) return;
      console.log(`[ssh-bridge] no SSH response in 10s — host unreachable cid=${connectionId.slice(0,8)} → ${_sshTarget}`);
      try { send({ type: 'error', message: 'Host unreachable (no SSH response in 10s)' }); } catch (_) {}
      try { client.end(); } catch (_) {}
    }, 10_000);
    const markProgress = () => { progressSeen = true; clearTimeout(unreachableTimer); };

    client.on('greeting', () => { markProgress(); sendPhase('greeting'); });
    client.on('banner', () => { markProgress(); sendPhase('banner'); });
    client.on('handshake', () => { markProgress(); sendPhase('handshake'); });

    client.on('ready', () => {
      sendPhase('ssh_ready');
      console.log(`[ssh-bridge] SSH ready: ${_sshTarget} cid=${connectionId.slice(0,8)}`);
      if (sshClient !== client) {
        console.log(`[ssh-bridge] ready fired after cleanup — ignoring cid=${connectionId.slice(0,8)}`);
        try { client.end(); } catch (_) {}
        return;
      }
      client.shell(
        { term: 'xterm-256color', cols: 80, rows: 24 },
        (err, stream) => {
          if (err) {
            send({ type: 'error', message: `Shell error: ${err.message}` });
            cleanup(err.message);
            return;
          }
          sshStream = stream;
          connecting = false;
          // Generate a reattachable session ID on first shell-ready. Sent to
          // the client immediately so it can include `?reattach=<id>` on any
          // subsequent reconnect attempt.
          mySessionId = randomBytes(16).toString('hex');
          send({ type: 'session_id', sessionId: mySessionId });
          send({ type: 'connected' });

          stream.on('data', (chunk) => {
            send({ type: 'output', data: chunk.toString('utf8') });
          });
          stream.stderr.on('data', (chunk) => {
            send({ type: 'output', data: chunk.toString('utf8') });
          });
          stream.on('close', () => {
            cleanup('SSH stream closed');
          });

          if (cfg.initialCommand) {
            stream.write(cfg.initialCommand + '\r');
          }
        }
      );
    });

    // ssh2 fires both 'end' and 'close' for a single tear-down; only handle once.
    let sshClosed = false;
    function sshCleanup(reason) {
      if (sshClosed) return;
      sshClosed = true;
      cleanup(reason);
    }

    client.on('error', (err) => {
      clearTimeout(unreachableTimer);
      send({ type: 'error', message: err.message });
      sshCleanup(err.message);
    });
    client.on('end', () => { clearTimeout(unreachableTimer); sshCleanup('SSH connection ended'); });
    client.on('close', () => { clearTimeout(unreachableTimer); sshCleanup('SSH connection closed'); });

    const sshConfig = {
      host: resolvedIp,
      port: parseInt(cfg.port) || 22,
      username: cfg.username,
      readyTimeout: 30000,  // 30s — Tailscale paths through DERP relays or
                            // to sleeping targets legitimately take longer
                            // than 10s. Bridge log evidence (2026-04-29):
                            // handshakes that eventually succeed on retry,
                            // synchronized halts across all 4 sessions
                            // every ~3 min when paths slow. 30s lets
                            // genuine slow handshakes complete; the client
                            // halt threshold absorbs anything truly dead.
      keepaliveInterval: 15000,  // SSH-layer keepalive every 15s
      keepaliveCountMax: 10,      // drop after 10 unanswered (~150s) — mobile needs longer grace
      hostVerifier(keyBuffer, verify) {
        // Compute SHA-256 fingerprint in OpenSSH format (#5)
        const fp = createHash('sha256').update(keyBuffer).digest('base64');
        const fingerprint = `SHA256:${fp}`;

        // Parse key type from SSH wire-format: uint32 len + ASCII string
        let keyType = 'unknown';
        try {
          const typeLen = keyBuffer.readUInt32BE(0);
          keyType = keyBuffer.slice(4, 4 + typeLen).toString('ascii');
        } catch (_) {}

        // Suspend KEX until the browser client accepts or rejects the key
        pendingVerify = verify;
        send({ type: 'hostkey', host: cfg.host, port: parseInt(cfg.port) || 22, keyType, fingerprint });
      },
    };

    if (cfg.privateKey) {
      sshConfig.privateKey = cfg.privateKey;
      if (cfg.passphrase) sshConfig.passphrase = cfg.passphrase;
    } else if (cfg.password) {
      sshConfig.password = cfg.password;
    } else {
      send({ type: 'error', message: 'No authentication method provided' });
      connecting = false;
      sshClient = null;
      return;
    }

    try {
      client.connect(sshConfig);
    } catch (err) {
      send({ type: 'error', message: `Connect failed: ${err.message}` });
      cleanup(err.message);
    }
  }

  ws.on('message', (raw) => {
    let msg;
    try { msg = JSON.parse(raw); } catch (_) {
      send({ type: 'error', message: 'Invalid JSON' });
      return;
    }

    switch (msg.type) {
      case 'connect':    connect(msg); break;
      case 'input':
        if (sshStream && typeof msg.data === 'string') sshStream.write(msg.data);
        break;
      case 'resize':
        if (sshStream && msg.cols && msg.rows)
          sshStream.setWindow(parseInt(msg.rows), parseInt(msg.cols), 0, 0);
        break;
      case 'disconnect': cleanup('User disconnected'); break;
      case 'ping': break; // application-layer keepalive (#29), no response needed
      case 'hostkey_response': // host key accept/reject from browser client (#5)
        if (pendingVerify) {
          const fn = pendingVerify;
          pendingVerify = null;
          fn(msg.accepted === true);
          // If rejected, ssh2 emits an error event which calls cleanup naturally
        }
        break;
      // [SFTP_ROUTER] -- every type in SFTP_HANDLER must be listed here
      case 'sftp_ls':
      case 'sftp_download':
      case 'sftp_download_start':
      case 'sftp_upload':
      case 'sftp_upload_start':
      case 'sftp_upload_chunk':
      case 'sftp_upload_end':
      case 'sftp_upload_cancel':
      case 'sftp_stat':
      case 'sftp_rename':
      case 'sftp_delete':
      case 'sftp_realpath':
        getSftp((err, sftp) => {
          if (err) { send({ type: 'sftp_error', requestId: msg.requestId, message: err.message }); return; }
          handleSftpMessage(msg, sftp, send, openUploads, ws, connectionId);
        });
        break;
      default: send({ type: 'error', message: `Unknown message type: ${msg.type}` });
    }
  });

  ws.on('close', () => {
    const t = connTracker.get(clientIP);
    if (t) t.active = Math.max(0, t.active - 1);

    // If SSH is alive and we have a reattachable session ID, park it in the
    // hold registry instead of tearing down. Caller (phone) can reconnect
    // within HOLD_GRACE_MS via `?reattach=<sessionId>` and resume seamlessly.
    if (sshClient && sshStream && mySessionId && !heldSessions.has(mySessionId)) {
      const state = {
        clientIP,
        sshClient,
        sshStream,
        sftpClient,
        sftpPending,
        openUploads,
        _sshTarget,
        ringBuffer: [],
        ringBufferBytes: 0,
        ringOverflow: false,
        graceTimer: null,
        captureChunk: null,
      };
      holdSession(mySessionId, state);
      // Release closure refs so cleanup() in this scope is a no-op for SSH.
      sshClient = null;
      sshStream = null;
      sftpClient = null;
      openUploads = new Map();
      console.log(`[ssh-bridge] WS closed, holding session ${mySessionId.slice(0,8)} for ${HOLD_GRACE_MS/1000}s: ${clientIP} cid=${connectionId.slice(0,8)} → ${_sshTarget} (active: ${t ? t.active : '?'})`);
      return;
    }

    console.log(`[ssh-bridge] WS closed: ${clientIP} cid=${connectionId.slice(0,8)} → ${_sshTarget} (active: ${t ? t.active : '?'})`);
    cleanup(null);
  });
  ws.on('error', (err) => {
    console.error(`[ssh-bridge] WebSocket error (${clientIP}):`, err.message);
    cleanup(err.message);
  });
});

// ─── Start ────────────────────────────────────────────────────────────────────

if (require.main === module) {
  server.listen(PORT, HOST, () => {
    console.log(`[ssh-bridge] Listening on http://${HOST}:${PORT}`);
  });

  process.on('SIGTERM', () => {
    console.log('[ssh-bridge] SIGTERM — shutting down');
    server.close(() => process.exit(0));
  });
  process.on('SIGINT', () => {
    console.log('[ssh-bridge] SIGINT — shutting down');
    server.close(() => process.exit(0));
  });
}

module.exports = { rewriteManifest, server, handleSftpMessage, isOriginAllowed, isPrivateIp, isCgnatIp, resumableUploads };
