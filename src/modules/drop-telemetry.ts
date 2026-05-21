/**
 * modules/drop-telemetry.ts — Auto-upload of connection-drop telemetry
 *
 * Every time a session recovers from a disconnected state (transitioning
 * `reconnecting` → `connected`), upload the last 24h of connect-log and
 * gesture-log to the server. The user's request: "don't turn it off
 * because this keeps happening" — we want passive, always-on visibility
 * into drops without requiring a manual bug-report tap.
 *
 * Throttle: max one upload per `THROTTLE_MS` window per device. Prevents
 * a tight reconnect loop from flooding the server. The throttle key is
 * stored in localStorage so it survives reloads.
 *
 * Failure is silent — drop telemetry should never block reconnect.
 */

import { getConnectLog } from './connect-log.js';
import { getGestureLog, logGesture } from './gesture-log.js';

const THROTTLE_KEY = 'mobissh.dropTelemetryLastUpload';
const THROTTLE_MS = 5 * 60_000; // 5 minutes

/** Independent throttle for gesture-anomaly uploads (#502 diagnostic).
 *  Looser than drop-telemetry's 5-min window because focus/IME anomalies
 *  during gestures are rarer and we want to catch most of them. */
const GESTURE_THROTTLE_KEY = 'mobissh.gestureUpload.lastT';
const GESTURE_THROTTLE_MS = 10 * 60_000; // 10 minutes

function _readLast(): number {
  const raw = localStorage.getItem(THROTTLE_KEY);
  if (!raw) return 0;
  const n = Number(raw);
  return isFinite(n) && n > 0 ? n : 0;
}

function _writeLast(t: number): void {
  try { localStorage.setItem(THROTTLE_KEY, String(t)); } catch { /* quota */ }
}

function _readGestureLast(): number {
  try {
    const raw = localStorage.getItem(GESTURE_THROTTLE_KEY);
    if (!raw) return 0;
    const n = Number(raw);
    return isFinite(n) && n > 0 ? n : 0;
  } catch { return 0; }
}

function _writeGestureLast(t: number): void {
  try { localStorage.setItem(GESTURE_THROTTLE_KEY, String(t)); } catch { /* quota */ }
}

/** Fire-and-forget upload of drop telemetry. Non-blocking, throttled,
 *  silent on failure. Returns immediately. */
export function uploadDropTelemetry(reason: string, sessionId?: string, host?: string): void {
  const now = Date.now();
  if (now - _readLast() < THROTTLE_MS) return; // too recent, skip

  // Mark BEFORE the fetch so concurrent fires (multiple sessions
  // recovering at once) don't all upload.
  _writeLast(now);

  const meta = document.querySelector<HTMLMetaElement>('meta[name="app-version"]');
  const payload = {
    kind: 'drop-recovery',
    reason,
    sessionId,
    host,
    ts: now,
    userAgent: navigator.userAgent,
    url: location.href,
    version: meta?.content ?? 'unknown',
    connectLog: getConnectLog(),
    gestureLog: getGestureLog(),
  };

  void fetch('api/drop-telemetry', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  }).catch(() => { /* silent */ });
}

/**
 * Fire-and-forget upload of gesture-anomaly telemetry (#502 diagnostic).
 *
 * Trigger conditions (any one of these, evaluated by selection.ts at gesture
 * window close):
 *   - focusin on .xterm-helper-textarea during a gesture window
 *   - visualViewport.resize with |deltaH| > 100 during a gesture window
 *   - IME state changed during the gesture window
 *
 * Throttle: 1 per `GESTURE_THROTTLE_MS` per device (localStorage-backed).
 * Independent of the drop-telemetry throttle.
 *
 * Always non-blocking, silent on failure. Also logs a `gesture_anomaly_uploaded`
 * event so the throttle behaviour is visible in the gesture log itself.
 */
export function uploadGestureAnomaly(reason: string, eventCount: number): void {
  const now = Date.now();
  const last = _readGestureLast();
  if (now - last < GESTURE_THROTTLE_MS) {
    // Record the throttled attempt so we can see "would have uploaded" in logs.
    try {
      logGesture('gesture_anomaly_uploaded', {
        reason,
        eventCount,
        status: 'throttled',
        sinceLastMs: now - last,
      });
    } catch { /* logging must never throw */ }
    return;
  }

  // Mark BEFORE the fetch so concurrent fires don't all upload.
  _writeGestureLast(now);

  const meta = document.querySelector<HTMLMetaElement>('meta[name="app-version"]');
  const gestureLog = getGestureLog();
  const payload = {
    kind: 'gesture-anomaly',
    reason,
    eventCount,
    ts: now,
    userAgent: navigator.userAgent,
    url: location.href,
    version: meta?.content ?? 'unknown',
    log: gestureLog,
  };

  try {
    logGesture('gesture_anomaly_uploaded', {
      reason,
      eventCount,
      status: 'sent',
      logEventCount: gestureLog.length,
    });
  } catch { /* logging must never throw */ }

  void fetch('api/gesture-telemetry', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  }).catch(() => { /* silent */ });
}
