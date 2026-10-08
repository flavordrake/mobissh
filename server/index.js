'use strict';

/**
 * MobiSSH — static file server + native install/telemetry endpoints.
 *
 * Serves the native install page and its artifacts and relays bug reports and
 * crash reports to the feedback service.
 *
 * The Claude Code approval bridge (/events SSE, /api/approval*, /api/hook) and
 * the PWA-only /api/drop-telemetry and /api/gesture-telemetry routes were
 * removed in #1261: no client subscribed or posted to them any more.
 *
 * The WebSocket SSH bridge and the SFTP-over-WS protocol that used to live here
 * were the PWA's transport; both were retired with the PWA in #1205. The native
 * app speaks SSH directly via dartssh2 and never used them.
 */

const http = require('http');
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const feedbackStore = require('./feedback-store');
const feedbackGuard = require('./feedback-guard');

const PORT = process.env.PORT || 8081;
const HOST = process.env.HOST || '0.0.0.0';

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
    // #1215: sideload self-update manifest (native-release-apk.sh).
    baseName === 'android-latest.json' ||
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

// ─── Bug-report / crash ingestion (#997) ─────────────────────────────────────
// Persistence for /api/bug-report and /api/native-crash lives in
// server/feedback-store.js, shared with the
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

async function handleFeedbackUpload(req, res, route = req.url) {
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
  feedbackGuard.recordUploadBytes(Buffer.byteLength(body));
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
  res.writeHead(result.status, { 'Content-Type': 'application/json' });
  res.end(result.body);
}

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js':   'application/javascript; charset=utf-8',
  '.css':  'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg':  'image/svg+xml',
  '.png':  'image/png',
  '.ico':  'image/x-icon',
  '.apk':  'application/vnd.android.package-archive',
  '.aab':  'application/octet-stream',
};

// ─── HTTP server (static files) ───────────────────────────────────────────────

const server = http.createServer((req, res) => {
  // POST /api/{bug-report,native-crash} — bug-report/crash ingestion (#997).
  // Proxied to the dedicated feedback service when FEEDBACK_SERVICE_URL is set,
  // with fail-open local fallback. Persistence lives in server/feedback-store.js.
  if (req.method === 'POST' && feedbackStore.FEEDBACK_ROUTES.includes(req.url)) {
    handleFeedbackUpload(req, res);
    return;
  }

  // POST /api/install-feedback — the install page's feedback form (#609/#1243).
  // A browser page cannot hold the feedback key (anything served to it is not a
  // secret), so this same-origin route adds the SERVER's key and runs the normal
  // /api/bug-report pipeline: rate limit + byte cap still apply, and an unset key
  // still blocks with 503. Rejected: injecting the key into native.html.
  // #1250: because the server adds the key, the route must prove the caller is
  // the install page itself, or any web page the owner visits could plant
  // reports (which agents read) with a cross-site text/plain POST.
  if (req.method === 'POST' && req.url === '/api/install-feedback') {
    const rej = feedbackGuard.checkSameOriginJson(req);
    if (rej) {
      res.writeHead(rej.status, { 'Content-Type': 'application/json' });
      res.end(rej.body);
      return;
    }
    req.headers['x-mobissh-key'] = process.env.MOBISSH_FEEDBACK_KEY || '';
    handleFeedbackUpload(req, res, '/api/bug-report');
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

  // /clear — nuke SW cache + storage so mobile browsers get a fresh start.
  // Visit https://<host>/clear on a device that still has the retired PWA installed.
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
      data = Buffer.from(html);
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

module.exports = { server };
