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
 *     { type: 'sftp_download_chunk', requestId, offset: number, data: string }  (base64)
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

// SSE clients for real-time telemetry push
const sseClients = new Set();

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
        send({ type: 'sftp_download_meta', requestId, size: stats.size });
        const rs = sftp.createReadStream(filePath);
        let offset = 0;
        rs.on('data', (chunk) => {
          const data = chunk.toString('base64');
          const currentOffset = offset;
          offset += chunk.length;
          rs.pause();
          ws.send(JSON.stringify({ type: 'sftp_download_chunk', requestId, offset: currentOffset, data }), () => {
            rs.resume();
          });
        });
        rs.on('end', () => {
          send({ type: 'sftp_download_end', requestId });
        });
        rs.on('error', (e) => {
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
      // Check for a resumable entry from a previous connection
      const existing = fingerprint ? resumableUploads.get(fingerprint) : null;
      if (existing && existing.stream && !existing.stream.destroyed && existing.connectionId === connectionId) {
        // Clear TTL timer — client reconnected in time
        if (existing.ttlTimer) { clearTimeout(existing.ttlTimer); existing.ttlTimer = null; }
        // Re-register under the new requestId in the per-connection map
        openUploads.set(requestId, { stream: existing.stream, offset: existing.offset, path: existing.path });
        existing.requestId = requestId;
        send({ type: 'sftp_upload_ack', requestId, offset: existing.offset });
      } else {
        // No resumable entry (or TTL expired) — create fresh
        if (openUploads.has(requestId)) { sftpErr('Upload already in progress for this requestId'); return; }
        const ws = sftp.createWriteStream(filePath);
        ws.on('error', err => {
          openUploads.delete(requestId);
          if (fingerprint) resumableUploads.delete(fingerprint);
          sftpErr(err.message);
        });
        const entry = { stream: ws, offset: 0, path: filePath, fingerprint, requestId, sftp, ttlTimer: null, connectionId };
        openUploads.set(requestId, { stream: ws, offset: 0, path: filePath });
        if (fingerprint) resumableUploads.set(fingerprint, entry);
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
      const upload = openUploads.get(requestId);
      if (!upload) { sftpErr('No upload in progress for this requestId'); return; }
      openUploads.delete(requestId);
      // Clean up resumable entry
      for (const [fp, re] of resumableUploads) {
        if (re.requestId === requestId) { resumableUploads.delete(fp); break; }
      }
      upload.stream.end(() => {
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

  // POST /api/bug-report — receive screenshot + logs from client, save to disk.
  if (req.method === 'POST' && req.url === '/api/bug-report') {
    let body = '';
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
      try {
        const data = JSON.parse(body);
        const { screenshot, logs, title, userAgent, url, version } = data;
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

        // Save metadata
        const meta = { title: title || `Bug report ${ts}`, version, url, userAgent, ts, screenshotFile };
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
const MAX_CONNS_PER_IP    = 10;       // max new connection attempts per window
const THROTTLE_WINDOW_MS  = 10_000;   // sliding window duration (ms)
const MAX_ACTIVE_PER_IP   = 8;        // max concurrent WS/SSH sessions per IP (multi-session + reconnect overlap)

// ip → { attempts: number, windowStart: number, active: number }
const connTracker = new Map();

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
  console.log(`[ssh-bridge] Client connected: ${clientIP} (active: ${track.active})`);

  let sshClient = null;
  let sshStream = null;
  let sftpClient = null;
  let sftpPending = null; // pending callbacks while SFTP channel is being opened
  let connecting = false;
  let pendingVerify = null; // hostVerifier callback waiting for client response (#5)
  const connectionId = randomBytes(16).toString('hex'); // unique per WS session
  const openUploads = new Map(); // requestId → { stream, offset, path } for chunked uploads

  function send(obj) {
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify(obj));
    }
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
      console.log(`[ssh-bridge] Session ended (${clientIP}): ${reason}`);
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
    sshClient = new Client();

    sshClient.on('ready', () => {
      console.log(`[ssh-bridge] SSH ready: ${cfg.username}@${cfg.host}:${cfg.port || 22}`);
      sshClient.shell(
        { term: 'xterm-256color', cols: 80, rows: 24 },
        (err, stream) => {
          if (err) {
            send({ type: 'error', message: `Shell error: ${err.message}` });
            cleanup(err.message);
            return;
          }
          sshStream = stream;
          connecting = false;
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

    sshClient.on('error', (err) => {
      send({ type: 'error', message: err.message });
      sshCleanup(err.message);
    });
    sshClient.on('end', () => { sshCleanup('SSH connection ended'); });
    sshClient.on('close', () => { sshCleanup('SSH connection closed'); });

    const sshConfig = {
      host: resolvedIp,
      port: parseInt(cfg.port) || 22,
      username: cfg.username,
      readyTimeout: 10000,  // 10s — fail fast, client retries 3x
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
      sshClient.connect(sshConfig);
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
    console.log(`[ssh-bridge] WebSocket closed: ${clientIP}`);
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
