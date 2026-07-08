'use strict';

/**
 * MobiSSH feedback service (#997) — dedicated bug-report/telemetry ingestion.
 *
 * Minimal Node HTTP server (no dependencies) extracted from server/index.js.
 * Handles ONLY the upload/telemetry routes; the SSH bridge / static server
 * (mobissh-prod) proxies these routes here so the app keeps posting to the
 * single Tailscale endpoint. Persistence semantics (file naming, size caps,
 * response bodies) live in server/feedback-store.js, shared with prod's
 * fail-open local fallback.
 *
 * Routes:
 *   POST /api/bug-report
 *   POST /api/drop-telemetry
 *   POST /api/gesture-telemetry
 *   POST /api/native-crash
 *   GET  /healthz              — liveness + config for feedback-ctl.sh
 *
 * Env:
 *   PORT                    listen port (default 8082)
 *   HOST                    bind address (default 0.0.0.0)
 *   UPLOADS_DIR             storage dir (default ../test-results/uploads)
 *   FEEDBACK_RETENTION_DAYS retention knob; 0/unset = keep everything
 *                           (default — the owner keeps traces, storage is cheap)
 */

const http = require('http');
const fs = require('fs');
const path = require('path');
const store = require('../server/feedback-store');

const PORT = process.env.PORT || 8082;
const HOST = process.env.HOST || '0.0.0.0';
const UPLOADS_DIR = process.env.UPLOADS_DIR
  ? path.resolve(process.env.UPLOADS_DIR)
  : path.resolve(__dirname, '..', 'test-results', 'uploads');
const RETENTION_DAYS = parseInt(process.env.FEEDBACK_RETENTION_DAYS || '', 10) || 0;
const APP_VERSION = require('./package.json').version || '0.0.0';

let GIT_HASH = 'unknown';
try { GIT_HASH = fs.readFileSync(path.join(__dirname, '..', '.git-hash'), 'utf8').trim(); } catch (_) {}

const server = http.createServer(async (req, res) => {
  if (req.method === 'GET' && req.url === '/healthz') {
    res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    res.end(JSON.stringify({
      ok: true,
      service: 'mobissh-feedback',
      version: APP_VERSION,
      hash: GIT_HASH,
      uploadsDir: UPLOADS_DIR,
      retentionDays: RETENTION_DAYS,
    }));
    return;
  }

  if (req.method === 'POST' && store.FEEDBACK_ROUTES.includes(req.url)) {
    const route = req.url;
    const maxBytes = route === '/api/native-crash' ? store.MAX_CRASH_BYTES : 0;
    let body;
    try {
      body = await store.readBody(req, maxBytes);
    } catch (err) {
      if (err.code === 'TOO_LARGE') {
        res.writeHead(413, { 'Content-Type': 'application/json' });
        res.end('{"error":"crash report exceeds 1MB"}');
      }
      return;
    }
    const result = store.handleFeedbackRequest(route, body, UPLOADS_DIR);
    res.writeHead(result.status, { 'Content-Type': 'application/json' });
    res.end(result.body);
    return;
  }

  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end('{"error":"not found"}');
});

if (require.main === module) {
  server.listen(PORT, HOST, () => {
    console.log(`[feedback-service] listening on ${HOST}:${PORT} uploads=${UPLOADS_DIR} retention=${RETENTION_DAYS || 'keep-everything'}`);
    fs.mkdirSync(UPLOADS_DIR, { recursive: true });
    // Retention sweep: on boot + daily. No-op at the default 0 (keep all).
    store.sweepRetention(UPLOADS_DIR, RETENTION_DAYS);
    setInterval(() => store.sweepRetention(UPLOADS_DIR, RETENTION_DAYS), 24 * 60 * 60 * 1000).unref();
  });
}

module.exports = { server, UPLOADS_DIR };
