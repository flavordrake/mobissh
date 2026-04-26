/**
 * modules/gesture-log.ts — Persistent client-side gesture log
 *
 * Captures every swipe / pinch / long-press / drag-select event into a
 * rolling 24h ring stored in localStorage. Mirrors connect-log.ts.
 *
 * Why: occasionally swipes/scrolls in tmux stop working and only an app
 * restart fixes it. By logging every gesture lifecycle event (start →
 * claim → end / cancel / listener error) plus the source element, we can
 * tell from a bug-report attachment whether the handler stopped firing
 * (no `gesture_term_touchstart` for hours) vs. fired but was suppressed
 * (touchstart with no claim) vs. errored mid-flight.
 *
 * Always on. Never log sensitive data.
 */

const STORAGE_KEY = 'mobissh.gestureLog.v1';
const MAX_AGE_MS = 24 * 60 * 60 * 1000;
const MAX_ENTRIES = 5000;

export type GestureLogType =
  | 'gesture_handler_init'
  | 'gesture_term_touchstart'
  | 'gesture_term_scroll_claim'
  | 'gesture_term_touchend'
  | 'gesture_term_touchcancel'
  | 'gesture_term_pinch_start'
  | 'gesture_term_pinch_end'
  | 'gesture_term_horiz_swipe'
  | 'gesture_session_swipe'
  | 'gesture_handle_swipe'
  | 'gesture_tabbar_swipe'
  | 'gesture_history_swipe'
  | 'gesture_long_press'
  | 'gesture_drag_select_start'
  | 'gesture_drag_select_end'
  | 'gesture_listener_error';

export interface GestureLogEntry {
  /** Unix ms */
  t: number;
  /** Compact event tag — see GestureLogType for the catalog. */
  e: GestureLogType;
  /** Free-form structured payload. Kept small. */
  d?: Record<string, unknown>;
}

let _buffer: GestureLogEntry[] = _read();

function _read(): GestureLogEntry[] {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw) as unknown;
    if (!Array.isArray(parsed)) return [];
    return parsed as GestureLogEntry[];
  } catch {
    return [];
  }
}

function _write(): void {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(_buffer));
  } catch (err) {
    _buffer = _buffer.slice(Math.floor(_buffer.length / 2));
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(_buffer));
    } catch (_) {
      console.warn('[gesture-log] storage write failed:', err);
    }
  }
}

function _prune(): void {
  const cutoff = Date.now() - MAX_AGE_MS;
  let i = 0;
  while (i < _buffer.length && _buffer[i]!.t < cutoff) i++;
  if (i > 0) _buffer.splice(0, i);
  if (_buffer.length > MAX_ENTRIES) {
    _buffer.splice(0, _buffer.length - MAX_ENTRIES);
  }
}

/** Append one gesture event. */
export function logGesture(
  e: GestureLogType,
  d?: Record<string, unknown>,
): void {
  const entry: GestureLogEntry = { t: Date.now(), e };
  if (d && Object.keys(d).length > 0) entry.d = d;
  _buffer.push(entry);
  _prune();
  _write();
}

/** Compact tag#id summary of an event target — useful to correlate which
 *  element the touch landed on without leaking content. */
export function gestureTarget(el: EventTarget | null): string {
  if (!(el instanceof Element)) return '';
  const tag = el.tagName.toLowerCase();
  return el.id ? `${tag}#${el.id}` : tag;
}

/** Read all entries, optionally filtered to last `maxAgeMs`. */
export function getGestureLog(maxAgeMs: number = MAX_AGE_MS): GestureLogEntry[] {
  _prune();
  if (maxAgeMs >= MAX_AGE_MS) return [..._buffer];
  const cutoff = Date.now() - maxAgeMs;
  return _buffer.filter((e) => e.t >= cutoff);
}

/** Format a single entry for human inspection. */
export function formatGestureLogEntry(entry: GestureLogEntry): string {
  const iso = new Date(entry.t).toISOString();
  const data = entry.d ? ` ${JSON.stringify(entry.d)}` : '';
  return `${iso} ${entry.e}${data}`;
}

/** Render the entire (24h-windowed) log as plain text. */
export function formatGestureLog(): string {
  return getGestureLog().map(formatGestureLogEntry).join('\n');
}

/** Wipe the log entirely. */
export function clearGestureLog(): void {
  _buffer = [];
  _write();
}

/** Trigger a browser download of the log as JSON. */
export function downloadGestureLog(): void {
  const ts = new Date().toISOString().replace(/[:.]/g, '-');
  const blob = new Blob([JSON.stringify(getGestureLog(), null, 2)], {
    type: 'application/json',
  });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `mobissh-gesture-log-${ts}.json`;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => { URL.revokeObjectURL(url); }, 60_000);
}

/** Attached to bug reports — same as the JSON download but inline. */
export function getGestureLogForBugReport(): GestureLogEntry[] {
  return getGestureLog();
}
