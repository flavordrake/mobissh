'use strict';

/**
 * MobiSSH — static file server + native install/telemetry endpoints.
 *
 * Serves the native install page and its artifacts, relays bug reports and
 * telemetry to the feedback service, and hosts the Claude Code approval bridge
 * (SSE + /api/approval*).
 *
 * The WebSocket SSH bridge and the SFTP-over-WS protocol that used to live here
 * were the PWA's transport; both were retired with the PWA in #1205. The native
 * app speaks SSH directly via dartssh2 and never used them.
 */

const http = require('http');
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const { rewriteManifest } = require('./manifest');
const feedbackStore = require('./feedback-store');
const feedbackGuard = require('./feedback-guard');

const PORT = process.env.PORT || 8081;
const HOST = process.env.HOST || '0.0.0.0';
// BASE_PATH: set when served behind a reverse-proxy at a subpath (e.g. /ssh).
// Must start with / and have no trailing slash.  Example: BASE_PATH=/ssh
const BASE_PATH = (process.env.BASE_PATH || '').replace(/\/$/, '');

const PUBLIC_DIR = path.resolve(__dirname, '..', 'public');
// Persistent distribution dir for the native APK + its install page (#700).
// Bind-mounted from the host in docker-compose.prod.yml so these large, build-
// produced artifacts survive a container recreate AND the `container-ctl.sh push`
// hot-cp of public/ — neither of which carries them (they're not in the image,
// and `scripts/native-release-apk.sh` writes them here, not into public/). The
// static handler serves the native artifact names from here, falling back to
// PUBLIC_DIR when a file isn't present (e.g. before the first publish).
const NATIVE_DIST_DIR = process.env.NATIVE_DIST_DIR
  ? path.resolve(process.env.NATIVE_DIST_DIR)
  : path.resolve(__dirname, '..', 'native-dist');
// Exact basenames + the timestamped-APK pattern served from NATIVE_DIST_DIR.
function isNativeDistArtifact(baseName) {
  return (
    baseName === 'native.html' ||
    baseName === 'native-time.js' ||
    baseName === 'native-feedback.js' ||
    baseName === 'macos-latest.json' ||
    /^mobissh-native(-[\w.+-]+)?\.apk$/.test(baseName) ||
    // #1026: macOS desktop app bundle — the stable `mobissh-native-macos.zip`
    // alias + the versioned `mobissh-native-macos-<version>-<stamp>.zip`, built
    // on the Mac (scripts/mac/build-native-macos.sh) and published here by
    // scripts/publish-native-macos.sh. Unsigned bundle, no private key inside.
    /^mobissh-native-macos(-[\w.+-]+)?\.zip$/.test(baseName) ||
    // #966: signed Play Store App Bundle(s) — the stable `mobissh-release.aab`
    // alias + the versioned `mobissh-<version>-<stamp>.aab` (build-release-aab.sh).
    // Served so the owner can pull the bundle for a Play upload; the AAB carries
    // only the public signing cert, never the keystore private key.
    /^mobissh-[\w.+-]+\.aab$/.test(baseName)
  );
}

// #712: report whether the persistent native-dist bind is actually mounted +
// populated. A container recreated WITHOUT the docker-compose native-dist bind
// (e.g. a deploy from a checkout lacking the #700 mount) serves no APK/install
// page → the download URL 404s. Surface it loudly (startup log + /version) so a
// bare recreate is obvious instead of discovered via a 404 mid-test.
//   'mounted' — dir exists AND the install page is present (healthy)
//   'EMPTY'   — dir exists but native.html is missing (mounted, not published)
//   'MISSING' — dir does not exist (the bind was dropped — THE failure mode)
function nativeDistStatus() {
  try {
    if (!fs.existsSync(NATIVE_DIST_DIR)) return 'MISSING';
    return fs.existsSync(path.join(NATIVE_DIST_DIR, 'native.html'))
      ? 'mounted'
      : 'EMPTY';
  } catch (_) {
    return 'MISSING';
  }
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

// ─── Bug-report / telemetry ingestion (#997) ─────────────────────────────────
// Persistence for /api/bug-report, /api/drop-telemetry, /api/gesture-telemetry
// and /api/native-crash lives in server/feedback-store.js, shared with the
// dedicated feedback-service container (server-feedback/). When
// FEEDBACK_SERVICE_URL is set (docker-compose.prod.yml defaults it to
// http://mobissh-feedback:8082) the raw body is relayed to that service so the
// app keeps posting to the single Tailscale endpoint. If the service is
// unreachable the report is handled LOCALLY (fail-open — a bug report must
// never be lost because the telemetry container is down). Both sides write to
// the same host bind mount, so dev-loop consumers see the files either way.

const FEEDBACK_PROXY_TIMEOUT_MS = parseInt(process.env.FEEDBACK_PROXY_TIMEOUT_MS || '', 10) || 10_000;

/**
 * Relay a buffered feedback body to the feedback service and return its
 * response. The body is buffered (the local handlers always buffered too)
 * rather than piped so a transport failure can still fall back to local
 * handling with the full body. Service HTTP responses (4xx/5xx included) are
 * relayed verbatim; only transport errors (DNS/connect/timeout) reject.
 *
 * #484: forward the X-MobiSSH-Key the client already authenticated with, so the
 * downstream feedback service (which runs the SAME shared guard) accepts the
 * relayed request. Prod and the service share MOBISSH_FEEDBACK_KEY in the deploy.
 */
function proxyFeedbackBody(serviceUrl, route, body, contentType, authKey) {
  return new Promise((resolve, reject) => {
    const headers = {
      'Content-Type': contentType || 'application/json',
      'Content-Length': Buffer.byteLength(body),
    };
    if (authKey) headers['X-MobiSSH-Key'] = authKey;
    const proxyReq = http.request(new URL(serviceUrl + route), {
      method: 'POST',
      headers,
      timeout: FEEDBACK_PROXY_TIMEOUT_MS,
    }, (proxyRes) => {
      let out = '';
      proxyRes.on('data', (c) => { out += c; });
      proxyRes.on('end', () => resolve({ status: proxyRes.statusCode || 502, body: out }));
    });
    proxyReq.on('timeout', () => proxyReq.destroy(new Error('feedback service timeout')));
    proxyReq.on('error', reject);
    proxyReq.end(body);
  });
}

async function handleFeedbackUpload(req, res) {
  const route = req.url;
  // #484: auth + per-IP rate limit BEFORE buffering, so an unauthenticated or
  // over-quota caller can never buffer/decode an attacker-sized body.
  const rej = feedbackGuard.preflight(req);
  if (rej) {
    res.writeHead(rej.status, { 'Content-Type': 'application/json' });
    res.end(rej.body);
    return;
  }
  const maxBytes = route === '/api/native-crash'
    ? feedbackStore.MAX_CRASH_BYTES
    : feedbackGuard.maxFeedbackBytes();
  let body;
  try {
    body = await feedbackStore.readBody(req, maxBytes);
  } catch (err) {
    if (err.code === 'TOO_LARGE') {
      // Connection: close so the unread oversized body is discarded and the
      // 413 reaches the client cleanly (no socket-hang-up race) (#484).
      res.writeHead(413, { 'Content-Type': 'application/json', 'Connection': 'close' });
      res.end('{"error":"request body too large"}');
    }
    return;
  }
  // Read per-request (not at boot) so tests can toggle it; the deployed value
  // comes from docker-compose.prod.yml env — activating it is an explicit
  // container recreate, never a silent flip.
  const serviceUrl = (process.env.FEEDBACK_SERVICE_URL || '').replace(/\/+$/, '');
  if (serviceUrl) {
    try {
      const relayed = await proxyFeedbackBody(serviceUrl, route, body, req.headers['content-type'], req.headers['x-mobissh-key']);
      console.log(`[feedback-proxy] ${route} -> ${serviceUrl} (${relayed.status})`);
      res.writeHead(relayed.status, { 'Content-Type': 'application/json' });
      res.end(relayed.body);
      return;
    } catch (err) {
      // Fail-open: never lose a report because the telemetry container is down.
      console.error(`[feedback-proxy] ${route} -> ${serviceUrl} unreachable (${err.message}) — falling back to LOCAL handling`);
    }
  }
  const reportDir = path.join(__dirname, '..', 'test-results', 'uploads');
  const result = feedbackStore.handleFeedbackRequest(route, body, reportDir);
  if (result.sse) sseBroadcast(result.sse.event, result.sse.data);
  res.writeHead(result.status, { 'Content-Type': 'application/json' });
  res.end(result.body);
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
  '.apk':  'application/vnd.android.package-archive',
  '.aab':  'application/octet-stream',
};

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

        // Broadcast on SSE so a connected client shows the approval bar. The
        // parallel WS fan-out went with the PWA's SSH bridge (#1205); SSE was
        // always the primary channel.
        const approvalData = { ...data, requestId, label };
        sseBroadcast('approval', approvalData);

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
        // Broadcast to SSE clients (the only channel since #1205 retired the
        // PWA's WebSocket bridge; it was always the primary one).
        sseBroadcast(sseEvent, data);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end('{"ok":true}');
      } catch {
        res.writeHead(400);
        res.end('{"error":"invalid json"}');
      }
    });
    return;
  }

  // POST /api/{bug-report,drop-telemetry,gesture-telemetry,native-crash} —
  // bug-report/telemetry ingestion (#997). Proxied to the dedicated feedback
  // service when FEEDBACK_SERVICE_URL is set, with fail-open local fallback.
  // Persistence semantics live in server/feedback-store.js.
  if (req.method === 'POST' && feedbackStore.FEEDBACK_ROUTES.includes(req.url)) {
    handleFeedbackUpload(req, res);
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
    res.end(
      JSON.stringify({
        version: APP_VERSION,
        hash: GIT_HASH,
        nativeDist: nativeDistStatus(), // #712 — 'mounted' | 'EMPTY' | 'MISSING'
      })
    );
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
  const relName = rel === '/' || rel === '' ? 'index.html' : rel;
  const baseName = path.basename(relName);

  // Native dist artifacts (#700): serve from the persistent NATIVE_DIST_DIR so a
  // container recreate / public-hot-push can't 404 the download URL. baseName is
  // path.basename (no separators) matched against a strict allowlist, so it's a
  // safe direct join. Falls back to PUBLIC_DIR if not yet published there.
  let serveRoot = PUBLIC_DIR;
  let filePath;
  if (isNativeDistArtifact(baseName) && fs.existsSync(path.join(NATIVE_DIST_DIR, baseName))) {
    serveRoot = NATIVE_DIST_DIR;
    filePath = path.join(NATIVE_DIST_DIR, baseName);
  } else {
    filePath = path.join(PUBLIC_DIR, relName);
  }

  if (!filePath.startsWith(serveRoot + path.sep) && filePath !== serveRoot) {
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
    const headers = {
      'Content-Type': MIME[ext] || 'application/octet-stream',
      'Cache-Control': 'no-store',
      // Advertise byte size + range support (#dx): without Content-Length Node
      // falls back to chunked transfer, so downloaders (ntfy / browser) can't
      // show total/progress/completion and can't resume or parallelize. `data`
      // already holds the full file, so this is free; Range lets a big download
      // (the APK) resume/parallelize.
      'Accept-Ranges': 'bytes',
      'Content-Security-Policy': [
        "default-src 'self'",
        "script-src 'self'",
        "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
        "font-src 'self' https://fonts.gstatic.com",
        "connect-src 'self'",
        "img-src 'self' data: blob:",
        "media-src 'self' blob:",
        "worker-src 'self'",
        "frame-ancestors 'none'",
      ].join('; '),
    };
    // Honor a single byte-range (bytes=start-end | start- | -suffix) so a large
    // download can resume / parallelize. Sliced from the in-memory buffer.
    const total = data.length;
    const rangeMatch = /^bytes=(\d*)-(\d*)$/.exec((req.headers.range || '').trim());
    if (rangeMatch) {
      let start = rangeMatch[1] === '' ? null : parseInt(rangeMatch[1], 10);
      let end = rangeMatch[2] === '' ? null : parseInt(rangeMatch[2], 10);
      if (start === null) {
        // suffix range: last N bytes
        start = end === null ? 0 : Math.max(0, total - end);
        end = total - 1;
      } else if (end === null || end >= total) {
        end = total - 1;
      }
      if (start > end || start >= total) {
        res.writeHead(416, {
          'Content-Range': `bytes */${total}`,
          'Accept-Ranges': 'bytes',
        });
        res.end();
        return;
      }
      headers['Content-Length'] = end - start + 1;
      headers['Content-Range'] = `bytes ${start}-${end}/${total}`;
      res.writeHead(206, headers);
      res.end(data.subarray(start, end + 1));
      return;
    }
    headers['Content-Length'] = total;
    res.writeHead(200, headers);
    res.end(data);
  });
});

// ─── Start ────────────────────────────────────────────────────────────────────

if (require.main === module) {
  server.listen(PORT, HOST, () => {
    console.log(`[ssh-bridge] Listening on http://${HOST}:${PORT}`);
    // #712 — loud check that the persistent native-dist bind is present. A
    // container recreated without the docker-compose native-dist mount serves
    // no APK/install page (download URL 404s). Make a bare recreate obvious in
    // `docker logs` instead of waiting for a 404 mid-test.
    const ndStatus = nativeDistStatus();
    if (ndStatus === 'mounted') {
      console.log(`[ssh-bridge] native-dist OK (${NATIVE_DIST_DIR})`);
    } else {
      console.error(
        `[ssh-bridge] !!! native-dist ${ndStatus} at ${NATIVE_DIST_DIR} — ` +
          'the APK + install page will 404. The container was recreated WITHOUT ' +
          'the docker-compose native-dist bind (#700/#712). Redeploy from the ' +
          'container workspace via scripts/container-ctl.sh restart. /version reports nativeDist.'
      );
    }
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

module.exports = { rewriteManifest, server };
