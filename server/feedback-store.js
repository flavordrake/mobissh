'use strict';

/**
 * server/feedback-store.js — bug-report/telemetry persistence (#997).
 *
 * Single source of truth for the four feedback ingestion routes:
 *
 *   POST /api/bug-report         user-filed report (screenshot, frames, logs, traces)
 *   POST /api/drop-telemetry     auto-upload on connection-drop recovery
 *   POST /api/gesture-telemetry  auto-upload on gesture/IME anomaly (#502)
 *   POST /api/native-crash       native APK crash reports (#501)
 *
 * Extracted VERBATIM from server/index.js so the dedicated feedback-service
 * container (server-feedback/index.js) and mobissh-prod's fail-open local
 * fallback share identical file-naming contracts, size caps, and response
 * bodies. The dev-loop consumers (scripts/watch-bug-reports.sh,
 * scripts/assemble-repro.sh, the replay harness, scripts/paint-replay.sh)
 * depend on the exact filenames written here — do not change them.
 *
 * Filename contract: every file is named from a server-generated ISO stamp
 * (`2026-07-08T14-15-16`) plus a fixed suffix. No user-controlled path
 * components ever reach the filesystem — that IS the sanitization.
 */

const fs = require('fs');
const path = require('path');

// Request-body cap for /api/native-crash (stack traces are far smaller).
const MAX_CRASH_BYTES = 1024 * 1024;
// Per-file cap for the gesture-telemetry log sidecar.
const MAX_GESTURE_LOG_BYTES = 1024 * 1024;
// Frame-burst guard for bug-report repro recordings.
const MAX_FRAMES = 120;
// Per-decoded-image cap (#484): a screenshot/frame whose DECODED bytes exceed
// this is skipped, bounding per-file disk even when the encoded request body
// slipped under the front-door byte cap. Read per-call so tests can toggle it.
function maxImageDecodedBytes() {
  return parseInt(process.env.MOBISSH_FEEDBACK_IMAGE_MAX_BYTES || '', 10) || 4 * 1024 * 1024;
}
// Server-side backstop caps for replay traces (client already bounds the rings).
const MAX_BYTE_EVENTS = 8192;
const MAX_SCROLL_EVENTS = 8192;
const MAX_SENT_SGR_EVENTS = 8192;

/** The routes this store handles (also used by the prod proxy gate). */
const FEEDBACK_ROUTES = [
  '/api/bug-report',
  '/api/drop-telemetry',
  '/api/gesture-telemetry',
  '/api/native-crash',
];

/** Server-generated timestamp used as the filename prefix for every artifact. */
function stampNow() {
  return new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
}

/**
 * Buffer a request body, optionally enforcing a byte cap. Resolves with the
 * body as a utf8 string. Rejects with err.code === 'TOO_LARGE' when the cap is
 * exceeded — the caller answers 413 (with Connection: close). readBody does NOT
 * destroy the socket itself: destroying it before the caller writes the 413
 * truncates the response into a client-side "socket hang up" (#484).
 *
 * A declared Content-Length over the cap is rejected up front, so an oversized
 * request is refused WITHOUT buffering (or later base64-decoding) the body.
 */
function readBody(req, maxBytes) {
  return new Promise((resolve, reject) => {
    const tooLarge = () => {
      const err = new Error(`body exceeds ${maxBytes} bytes`);
      err.code = 'TOO_LARGE';
      return err;
    };
    if (maxBytes) {
      const declared = parseInt(req.headers['content-length'] || '', 10);
      if (Number.isFinite(declared) && declared > maxBytes) { reject(tooLarge()); return; }
    }
    const chunks = [];
    let total = 0;
    let aborted = false;
    req.on('data', (chunk) => {
      if (aborted) return;
      const buf = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      total += buf.length;
      if (maxBytes && total > maxBytes) {
        aborted = true;
        reject(tooLarge());
        return;
      }
      chunks.push(buf);
    });
    req.on('end', () => {
      if (!aborted) resolve(Buffer.concat(chunks).toString('utf8'));
    });
    req.on('error', (err) => {
      if (!aborted) reject(err);
    });
  });
}

/** Save a drop-telemetry payload. Returns the meta object written to disk. */
function saveDropTelemetry(data, reportDir) {
  const { kind, reason, sessionId, host, ts, userAgent, url, version, connectLog, gestureLog } = data;
  const stamp = stampNow();
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
  return meta;
}

/** Save a gesture-telemetry payload. Returns the meta object written to disk. */
function saveGestureTelemetry(data, reportDir) {
  const { kind, reason, eventCount, ts, userAgent, url, version, log } = data;
  const stamp = stampNow();
  fs.mkdirSync(reportDir, { recursive: true });

  let logFile = '';
  if (Array.isArray(log) && log.length > 0) {
    logFile = `${stamp}-gesture-telemetry.gesture-log.json`;
    const logPath = path.join(reportDir, logFile);
    const logBody = JSON.stringify(log, null, 2);
    // Cap individual log files at ~1MB to bound disk usage.
    const safeBody = Buffer.byteLength(logBody, 'utf8') > MAX_GESTURE_LOG_BYTES
      ? JSON.stringify(log.slice(-Math.floor(log.length / 2)), null, 2)
      : logBody;
    fs.writeFileSync(logPath, safeBody);
  }

  const meta = {
    kind: kind || 'gesture-anomaly',
    reason: reason || '',
    eventCount: typeof eventCount === 'number' ? eventCount : 0,
    ts: ts || Date.now(),
    stamp,
    userAgent: userAgent || '',
    url: url || '',
    version: version || '',
    logFile,
    logEventCount: Array.isArray(log) ? log.length : 0,
  };
  fs.writeFileSync(
    path.join(reportDir, `${stamp}-gesture-telemetry.json`),
    JSON.stringify(meta, null, 2),
  );
  console.log(`[gesture-telemetry] ${stamp} reason="${meta.reason}" events=${meta.eventCount} logEvents=${meta.logEventCount}`);
  return meta;
}

/**
 * Save a native crash report from the RAW request body. Non-JSON bodies are
 * preserved as `.raw` so a crash report is never lost. Returns
 * { raw, file, kind, stamp } — `raw` true when the body did not parse.
 */
function saveNativeCrash(rawBody, reportDir) {
  const stamp = stampNow();
  fs.mkdirSync(reportDir, { recursive: true });
  let parsed = null;
  try {
    parsed = JSON.parse(rawBody);
  } catch (parseErr) {
    const rawFile = path.join(reportDir, `${stamp}-native-crash.raw`);
    fs.writeFileSync(rawFile, rawBody);
    console.warn(`[native-crash] non-JSON body saved to ${rawFile}: ${parseErr.message}`);
    return { raw: true, file: path.basename(rawFile), kind: 'unknown', stamp };
  }
  const kind = (parsed && parsed.kind) || 'unknown';
  const outFile = path.join(reportDir, `${stamp}-native-crash.json`);
  fs.writeFileSync(outFile, JSON.stringify(parsed, null, 2));
  const errMsg = (parsed && parsed.error) || '';
  console.log(`[native-crash] ${stamp} kind="${kind}" error="${String(errMsg).slice(0, 120)}"`);
  return { raw: false, file: path.basename(outFile), kind, stamp };
}

/** Save a bug-report payload. Returns the meta object written to disk. */
function saveBugReport(data, reportDir) {
  const { screenshot, frames, logs, title, comment, userAgent, url, version, connectLog, gestureLog, byteTrace, scrollTrace, sentSgrTrace, grid } = data;
  const ts = stampNow();
  fs.mkdirSync(reportDir, { recursive: true });

  // Save screenshot
  const imageCap = maxImageDecodedBytes();
  let screenshotFile = '';
  if (screenshot) {
    const imgData = screenshot.replace(/^data:image\/\w+;base64,/, '');
    const buf = Buffer.from(imgData, 'base64');
    if (buf.length > imageCap) {
      console.warn(`[bug-report] screenshot skipped: decoded ${buf.length}B exceeds ${imageCap}B cap`);
    } else {
      screenshotFile = `${ts}-bug-report.png`;
      fs.writeFileSync(path.join(reportDir, screenshotFile), buf);
      console.log(`[bug-report] screenshot: ${screenshotFile}`);
    }
  }

  // #repro: a recorded burst of frames (in-app 10s "video"). Save each as a
  // zero-padded PNG so the orchestrator can assemble them with ffmpeg
  // (`ffmpeg -framerate 5 -i ${ts}-bug-report.frame-%03d.png out.mp4`).
  let frameCount = 0;
  let framesPattern = '';
  if (Array.isArray(frames) && frames.length > 0) {
    const n = Math.min(frames.length, MAX_FRAMES);
    for (let i = 0; i < n; i++) {
      const f = frames[i];
      if (typeof f !== 'string' || !f) continue;
      const fData = f.replace(/^data:image\/\w+;base64,/, '');
      const fbuf = Buffer.from(fData, 'base64');
      if (fbuf.length > imageCap) continue; // #484: skip an oversized frame
      const name = `${ts}-bug-report.frame-${String(i + 1).padStart(3, '0')}.png`;
      fs.writeFileSync(path.join(reportDir, name), fbuf);
      frameCount++;
    }
    framesPattern = `${ts}-bug-report.frame-%03d.png`;
    console.log(`[bug-report] frames: ${frameCount} (${framesPattern})`);
  }

  // Full free-text body. The native in-app feedback (#661) sends the ENTIRE
  // multi-line note as `comment` (no truncation). The web form
  // (public/native-feedback.js) sends the full note as `logs` and only a
  // first-line `title`. Resolve the full body from `comment` first, falling
  // back to `logs`, and persist it into the .json meta so the orchestrator's
  // watcher — which reads the .json — gets the complete note.
  const fullComment = (typeof comment === 'string' && comment.length > 0)
    ? comment
    : (typeof logs === 'string' ? logs : '');

  // Save logs / full comment as a sidecar text file too.
  const logBody = (typeof logs === 'string' && logs.length > 0) ? logs : fullComment;
  if (logBody) {
    fs.writeFileSync(path.join(reportDir, `${ts}-bug-report.log`), logBody);
    console.log(`[bug-report] logs: ${ts}-bug-report.log`);
  }

  // 24h connect log — every connect/reconnect/state-transition event.
  let connectLogFile = '';
  if (Array.isArray(connectLog) && connectLog.length > 0) {
    connectLogFile = `${ts}-bug-report.connect-log.json`;
    fs.writeFileSync(
      path.join(reportDir, connectLogFile),
      JSON.stringify(connectLog, null, 2),
    );
    console.log(`[bug-report] connect log: ${connectLogFile} (${connectLog.length} events)`);
  }

  // 24h gesture log — every swipe / pinch / long-press / drag-select.
  let gestureLogFile = '';
  if (Array.isArray(gestureLog) && gestureLog.length > 0) {
    gestureLogFile = `${ts}-bug-report.gesture-log.json`;
    fs.writeFileSync(
      path.join(reportDir, gestureLogFile),
      JSON.stringify(gestureLog, null, 2),
    );
    console.log(`[bug-report] gesture log: ${gestureLogFile} (${gestureLog.length} events)`);
  }

  // #790: the replay-harness trace — raw bytes that reached the terminal
  // (byteTrace) + scroll-offset events (scrollTrace) + the viewport grid.
  let byteTraceFile = '';
  let byteTraceEventCount = 0;
  let scrollTraceEventCount = 0;
  const hasByteTrace = Array.isArray(byteTrace) && byteTrace.length > 0;
  const hasScrollTrace = Array.isArray(scrollTrace) && scrollTrace.length > 0;
  if (hasByteTrace || hasScrollTrace) {
    const cappedBytes = hasByteTrace ? byteTrace.slice(-MAX_BYTE_EVENTS) : [];
    const cappedScroll = hasScrollTrace ? scrollTrace.slice(-MAX_SCROLL_EVENTS) : [];
    byteTraceEventCount = cappedBytes.length;
    scrollTraceEventCount = cappedScroll.length;
    byteTraceFile = `${ts}-bug-report.byte-trace.json`;
    fs.writeFileSync(
      path.join(reportDir, byteTraceFile),
      JSON.stringify({
        grid: (grid && typeof grid === 'object') ? grid : null,
        byteTrace: cappedBytes,
        scrollTrace: cappedScroll,
      }, null, 2),
    );
    console.log(`[bug-report] byte trace: ${byteTraceFile} (${byteTraceEventCount} byte events, ${scrollTraceEventCount} scroll events)`);
  }

  // #793: the sent-SGR trace — synthesized mouse/wheel SGR reports the app
  // SENT to the remote. Filtered client-side to SGR-mouse reports ONLY.
  let sentSgrTraceFile = '';
  let sentSgrTraceEventCount = 0;
  const hasSentSgrTrace = Array.isArray(sentSgrTrace) && sentSgrTrace.length > 0;
  if (hasSentSgrTrace) {
    const cappedSentSgr = sentSgrTrace.slice(-MAX_SENT_SGR_EVENTS);
    sentSgrTraceEventCount = cappedSentSgr.length;
    sentSgrTraceFile = `${ts}-bug-report.sent-sgr-trace.json`;
    fs.writeFileSync(
      path.join(reportDir, sentSgrTraceFile),
      JSON.stringify({
        grid: (grid && typeof grid === 'object') ? grid : null,
        sentSgrTrace: cappedSentSgr,
      }, null, 2),
    );
    console.log(`[bug-report] sent-SGR trace: ${sentSgrTraceFile} (${sentSgrTraceEventCount} events)`);
  }

  // Save metadata
  const meta = {
    title: title || `Bug report ${ts}`,
    // #661: persist the FULL comment (untruncated) into the meta JSON.
    comment: fullComment,
    version,
    url,
    userAgent,
    ts,
    screenshotFile,
    frameCount,
    framesPattern,
    connectLogFile,
    connectLogEventCount: Array.isArray(connectLog) ? connectLog.length : 0,
    gestureLogFile,
    gestureLogEventCount: Array.isArray(gestureLog) ? gestureLog.length : 0,
    byteTraceFile,
    byteTraceEventCount,
    scrollTraceEventCount,
    sentSgrTraceFile,
    sentSgrTraceEventCount,
    grid: (grid && typeof grid === 'object') ? grid : null,
  };
  fs.writeFileSync(path.join(reportDir, `${ts}-bug-report.json`), JSON.stringify(meta, null, 2));
  console.log(`[bug-report] saved: "${meta.title}"`);
  return meta;
}

/**
 * Dispatch a buffered feedback request body. Route must be one of
 * FEEDBACK_ROUTES. Returns { status, body, sse } where `body` is the exact
 * JSON response string and `sse` is an optional { event, data } for callers
 * that broadcast (mobissh-prod's local path; the standalone service has no
 * SSE clients and ignores it). Response bodies match the pre-extraction
 * server/index.js handlers byte-for-byte.
 */
function handleFeedbackRequest(route, rawBody, reportDir) {
  if (route === '/api/native-crash') {
    try {
      const r = saveNativeCrash(rawBody, reportDir);
      const body = r.raw
        ? JSON.stringify({ ok: true, raw: true, path: r.file })
        : JSON.stringify({ ok: true, path: r.file });
      return { status: 200, body, sse: { event: 'native-crash', data: { kind: r.kind, stamp: r.stamp, path: r.file } } };
    } catch (err) {
      console.error('[native-crash] write error:', err.message);
      return { status: 500, body: '{"error":"failed to persist crash"}' };
    }
  }

  // Parse + save under one catch, matching the pre-extraction handlers: any
  // failure (bad JSON or a write error) answered 400 "invalid json". Kept
  // byte-identical so existing clients/tests see no behavior change.
  try {
    return dispatchJsonRoute(route, JSON.parse(rawBody), reportDir);
  } catch (err) {
    const tag = route.replace('/api/', '');
    console.error(`[${tag}] parse error:`, err.message);
    return { status: 400, body: '{"error":"invalid json"}' };
  }
}

function dispatchJsonRoute(route, data, reportDir) {
  switch (route) {
    case '/api/drop-telemetry': {
      const meta = saveDropTelemetry(data, reportDir);
      return {
        status: 200,
        body: JSON.stringify({ ok: true, stamp: meta.stamp }),
        sse: { event: 'drop-telemetry', data: { reason: meta.reason, host: meta.host, stamp: meta.stamp } },
      };
    }
    case '/api/gesture-telemetry': {
      const meta = saveGestureTelemetry(data, reportDir);
      return {
        status: 200,
        body: JSON.stringify({ ok: true, stamp: meta.stamp }),
        sse: { event: 'gesture-telemetry', data: { reason: meta.reason, eventCount: meta.eventCount, stamp: meta.stamp } },
      };
    }
    case '/api/bug-report': {
      const meta = saveBugReport(data, reportDir);
      return {
        status: 200,
        body: JSON.stringify({ ok: true, saved: true }),
        sse: { event: 'bug-report', data: { title: meta.title, saved: true } },
      };
    }
    default:
      return { status: 404, body: '{"error":"unknown feedback route"}' };
  }
}

/**
 * Retention sweep: delete files in reportDir older than `days` (by mtime).
 * days <= 0 means keep everything (the default — the owner keeps traces;
 * storage is cheap). Returns the number of files deleted.
 */
function sweepRetention(reportDir, days) {
  if (!days || days <= 0) return 0;
  let deleted = 0;
  let names;
  try {
    names = fs.readdirSync(reportDir);
  } catch (_) {
    return 0; // dir not created yet — nothing to sweep
  }
  const cutoff = Date.now() - days * 24 * 60 * 60 * 1000;
  for (const name of names) {
    const p = path.join(reportDir, name);
    try {
      const st = fs.statSync(p);
      if (st.isFile() && st.mtimeMs < cutoff) {
        fs.unlinkSync(p);
        deleted++;
      }
    } catch (_) { /* raced or unreadable — skip */ }
  }
  if (deleted > 0) console.log(`[retention] deleted ${deleted} file(s) older than ${days}d from ${reportDir}`);
  return deleted;
}

module.exports = {
  FEEDBACK_ROUTES,
  MAX_CRASH_BYTES,
  readBody,
  stampNow,
  saveDropTelemetry,
  saveGestureTelemetry,
  saveNativeCrash,
  saveBugReport,
  handleFeedbackRequest,
  sweepRetention,
};
