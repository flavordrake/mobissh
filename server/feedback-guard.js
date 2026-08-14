'use strict';

/**
 * server/feedback-guard.js — shared hardening for the feedback ingestion routes (#484).
 *
 * The four feedback routes (/api/bug-report, /api/drop-telemetry,
 * /api/gesture-telemetry, /api/native-crash) accept attacker-sized JSON with
 * base64 screenshots/logs and write them to disk. Before this guard they were
 * unauthenticated, unbounded, and un-rate-limited on BOTH front doors
 * (server/index.js AND server-feedback/index.js) — a Tailnet-wide disk-fill /
 * DoS of the SSH bridge. This is the ONE place both doors import so neither is
 * a bypass (the duplication that let the second uncapped door exist).
 *
 * Three gates, all applied BEFORE the request body is buffered:
 *   1. AUTH (mandatory) — X-MobiSSH-Key must equal MOBISSH_FEEDBACK_KEY.
 *      Key UNSET => 503 (block, don't degrade — constitution art.2); missing or
 *      mismatched header => 401. Matches the existing idiom: the native app
 *      (native/lib/ui/feedback_overlay.dart) and the Cloudflare worker
 *      (infra/bug-report-worker/worker.js) already use X-MobiSSH-Key.
 *   2. RATE LIMIT — per-IP sliding window (in-memory, no dependency) => 429.
 *   3. BYTE CAP — maxFeedbackBytes() bounds the ENCODED body so an oversized
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

/** Client IP, honoring a single X-Forwarded-For hop (mirrors server/index.js). */
function getIP(req) {
  return req.headers['x-forwarded-for']?.split(',')[0]?.trim()
    || req.socket?.remoteAddress
    || 'unknown';
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

/** Auth first (cheap, header-only), then rate limit. Returns null when the
 *  request may proceed to buffering, else the rejection to send. */
function preflight(req) {
  const authRej = checkAuth(req);
  if (authRej) return authRej;
  return checkRateLimit(getIP(req));
}

/** Test helper — clear the rate-limit state between cases. */
function resetRateLimit() {
  rateHits.clear();
}

module.exports = {
  maxFeedbackBytes,
  getIP,
  checkAuth,
  checkRateLimit,
  preflight,
  resetRateLimit,
};
