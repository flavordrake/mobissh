'use strict';

/**
 * server/feedback-guard.js — shared hardening for the feedback ingestion routes (#484).
 *
 * The feedback routes (/api/bug-report, /api/native-crash, and
 * /api/install-feedback, which feeds /api/bug-report) accept attacker-sized
 * JSON with base64 screenshots/logs and write them to disk. Before this guard they were
 * unauthenticated, unbounded, and un-rate-limited on BOTH front doors
 * (server/index.js AND server-feedback/index.js) — a Tailnet-wide disk-fill /
 * DoS of the SSH bridge. This is the ONE place both doors import so neither is
 * a bypass (the duplication that let the second uncapped door exist).
 *
 * Four gates, all applied BEFORE the request body is buffered:
 *   1. AUTH (mandatory) — X-MobiSSH-Key must equal MOBISSH_FEEDBACK_KEY.
 *      Key UNSET => 503 (block, don't degrade — constitution art.2); missing or
 *      mismatched header => 401. Matches the existing idiom: the native app
 *      (native/lib/ui/feedback_overlay.dart) and the Cloudflare worker
 *      (infra/bug-report-worker/worker.js) already use X-MobiSSH-Key.
 *   2. RATE LIMIT — per-client sliding window (in-memory, no dependency) => 429,
 *      keyed by clientKey() (socket address or tailnet login, never XFF).
 *   3. BYTE BUDGET — a global rolling budget across all accepted uploads => 429.
 *   4. BYTE CAP — maxFeedbackBytes() bounds the ENCODED body so an oversized
 *      request is rejected at the buffering stage, never fully buffered/decoded.
 *
 * All env is read per-call (not at module load) so tests can toggle it and a
 * deploy activates a value by an explicit container recreate, never a silent flip.
 */

const { timingSafeEqual } = require('crypto');

/** Encoded-body cap for the non-crash routes (native-crash keeps its own 1MB
 *  cap in feedback-store). Default 16MB accommodates a 120-frame repro burst. */
function maxFeedbackBytes() {
  return parseInt(process.env.MOBISSH_FEEDBACK_MAX_BYTES || '', 10) || 16 * 1024 * 1024;
}

function rateMax() {
  return parseInt(process.env.MOBISSH_FEEDBACK_RATE_MAX || '', 10) || 30;
}

function rateWindowMs() {
  return parseInt(process.env.MOBISSH_FEEDBACK_RATE_WINDOW_MS || '', 10) || 60_000;
}

/** Rolling window and byte budget for ALL accepted uploads on this door (#1250).
 *  The per-client limit alone does not bound disk: a 16MB body 30 times a
 *  minute is ~29GB an hour. Default 1GB a day. */
function budgetBytes() {
  return parseInt(process.env.MOBISSH_FEEDBACK_BUDGET_BYTES || '', 10) || 1024 * 1024 * 1024;
}

function budgetWindowMs() {
  return parseInt(process.env.MOBISSH_FEEDBACK_BUDGET_WINDOW_MS || '', 10) || 24 * 60 * 60 * 1000;
}

const LOOPBACK = new Set(['127.0.0.1', '::1', '::ffff:127.0.0.1']);

/**
 * Rate-limit key for a request (#1250). Never X-Forwarded-For: any client sets
 * it, so keying on it let one peer reset its own limit at will.
 *
 * `tailscale serve` proxies from loopback and sets Tailscale-User-Login to the
 * tailnet identity (stripping any client-supplied copy), so behind it the login
 * is the caller. The header is trusted ONLY from a loopback socket: a direct
 * peer on the docker network could otherwise forge it. Everything else keys on
 * the socket address.
 */
function clientKey(req) {
  const addr = req.socket?.remoteAddress || 'unknown';
  const login = req.headers['tailscale-user-login'];
  if (login && LOOPBACK.has(addr)) return `ts:${login}`;
  return addr;
}

function rejection(status, error) {
  return { status, body: JSON.stringify({ error }) };
}

/**
 * Constant-time equality that does not leak whether the length matched.
 * Returns false for any non-string or empty input.
 */
function secretsEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string' || a.length === 0 || b.length === 0) return false;
  const bufA = Buffer.from(a);
  const bufB = Buffer.from(b);
  if (bufA.length !== bufB.length) return false;
  return timingSafeEqual(bufA, bufB);
}

/** Enforce the shared secret. Returns null when authorized, else a rejection. */
function checkAuth(req) {
  const key = process.env.MOBISSH_FEEDBACK_KEY || '';
  if (!key) return rejection(503, 'feedback auth not configured');
  const provided = req.headers['x-mobissh-key'] || '';
  if (!secretsEqual(provided, key)) return rejection(401, 'unauthorized');
  return null;
}

// ip -> array of request timestamps within the current window.
const rateHits = new Map();

/** Per-IP sliding-window rate limit. Returns null when allowed, else a rejection. */
function checkRateLimit(ip) {
  const now = Date.now();
  const windowMs = rateWindowMs();
  const cutoff = now - windowMs;
  const hits = (rateHits.get(ip) || []).filter((t) => t > cutoff);
  if (hits.length >= rateMax()) {
    rateHits.set(ip, hits);
    return rejection(429, 'rate limit exceeded');
  }
  hits.push(now);
  rateHits.set(ip, hits);
  // Opportunistic prune so the map can't grow unbounded across many IPs.
  if (rateHits.size > 4096) {
    for (const [k, v] of rateHits) {
      const kept = v.filter((t) => t > cutoff);
      if (kept.length === 0) rateHits.delete(k); else rateHits.set(k, kept);
    }
  }
  return null;
}

// [timestamp, bytes] for every accepted upload within the budget window.
let budgetLog = [];

function budgetUsed() {
  const cutoff = Date.now() - budgetWindowMs();
  budgetLog = budgetLog.filter(([t]) => t > cutoff);
  return budgetLog.reduce((sum, [, n]) => sum + n, 0);
}

/** Global byte budget (#1250). Rejects when the budget is spent, or when the
 *  declared Content-Length would overspend it, before anything is buffered. */
function checkBudget(req) {
  const declared = parseInt(req.headers['content-length'] || '', 10) || 0;
  if (budgetUsed() + declared > budgetBytes()) return rejection(429, 'upload budget exhausted');
  return null;
}

/** Count an accepted body against the global budget. */
function recordUploadBytes(n) {
  budgetLog.push([Date.now(), n]);
}

/**
 * #1250: /api/install-feedback adds the server's own key, so it must only
 * accept the install page itself. Requires a JSON content type (a cross-site
 * page cannot send one without a CORS preflight, which this server never
 * answers) and same-origin proof: Sec-Fetch-Site, which browsers set and pages
 * cannot forge, or, from a browser too old to send it, an Origin whose host is
 * the request's Host (or X-Forwarded-Host, in case the proxy rewrites Host).
 */
function checkSameOriginJson(req) {
  const type = String(req.headers['content-type'] || '').split(';')[0].trim().toLowerCase();
  if (type !== 'application/json') return rejection(415, 'content-type must be application/json');
  const site = req.headers['sec-fetch-site'];
  if (site) return site === 'same-origin' ? null : rejection(403, 'cross-origin request');
  let originHost;
  try { originHost = new URL(req.headers.origin).host; } catch { return rejection(403, 'origin required'); }
  const hosts = [req.headers.host, req.headers['x-forwarded-host']].filter(Boolean);
  return hosts.includes(originHost) ? null : rejection(403, 'cross-origin request');
}

/** Auth first (cheap, header-only), then rate limit, then the global byte
 *  budget. Returns null when the request may proceed to buffering, else the
 *  rejection to send. */
function preflight(req) {
  const authRej = checkAuth(req);
  if (authRej) return authRej;
  return checkRateLimit(clientKey(req)) || checkBudget(req);
}

/** Test helper — clear the rate-limit and budget state between cases. */
function resetRateLimit() {
  rateHits.clear();
  budgetLog = [];
}

module.exports = {
  maxFeedbackBytes,
  clientKey,
  checkAuth,
  checkRateLimit,
  checkBudget,
  checkSameOriginJson,
  recordUploadBytes,
  preflight,
  resetRateLimit,
};
