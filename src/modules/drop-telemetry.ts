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
import { getGestureLog } from './gesture-log.js';

const THROTTLE_KEY = 'mobissh.dropTelemetryLastUpload';
const THROTTLE_MS = 5 * 60_000; // 5 minutes

function _readLast(): number {
  const raw = localStorage.getItem(THROTTLE_KEY);
  if (!raw) return 0;
  const n = Number(raw);
  return isFinite(n) && n > 0 ? n : 0;
}

function _writeLast(t: number): void {
  try { localStorage.setItem(THROTTLE_KEY, String(t)); } catch { /* quota */ }
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
