/**
 * modules/connect-log.ts — Persistent client-side connection log
 *
 * Captures every connection-state event (WS open/close, SSH ready/error,
 * reconnect attempts, diagnostic probes, state transitions, network online/
 * offline) into a rolling 24h ring stored in localStorage. Surfaced to the
 * user via Settings (Clear / Download) and included in bug reports.
 *
 * Always on. Never log sensitive data — usernames are OK (already in the
 * profile metadata), but never log passwords, keys, or passphrases.
 */

const STORAGE_KEY = 'mobissh.connectLog.v1';
const MAX_AGE_MS = 24 * 60 * 60 * 1000;
const MAX_ENTRIES = 5000; // hard cap so a runaway log can't fill localStorage

export type ConnectLogType =
  | 'ws_open'
  | 'ws_close'
  | 'ws_error'
  | 'ws_message_parse_fail'
  | 'ssh_connecting'
  | 'ssh_ready'
  | 'ssh_error'
  | 'ssh_disconnected'
  | 'state_transition'
  | 'reconnect_scheduled'
  | 'reconnect_halt'
  | 'reconnect_attempt'
  | 'diag_start'
  | 'diag_result'
  | 'net_online'
  | 'net_offline'
  | 'visibility_resume'
  | 'visibility_hide'
  | 'session_create'
  | 'session_close'
  | 'app_start'
  | 'app_resume';

export interface ConnectLogEntry {
  /** Unix ms */
  t: number;
  /** Compact event tag — see ConnectLogType for the catalog. */
  e: ConnectLogType;
  /** Session id when known. */
  sid?: string;
  /** Free-form structured payload. Kept small. */
  d?: Record<string, unknown>;
}

let _buffer: ConnectLogEntry[] = _read();

function _read(): ConnectLogEntry[] {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw) as unknown;
    if (!Array.isArray(parsed)) return [];
    return parsed as ConnectLogEntry[];
  } catch {
    return [];
  }
}

function _write(): void {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(_buffer));
  } catch (err) {
    // Quota exceeded — drop the oldest half and try again.
    _buffer = _buffer.slice(Math.floor(_buffer.length / 2));
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(_buffer));
    } catch (_) {
      // Give up silently; logging shouldn't break the app.
      console.warn('[connect-log] storage write failed:', err);
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

/** Append one event. Sanitize callers — never pass secrets. */
export function logConnect(
  e: ConnectLogType,
  sid?: string,
  d?: Record<string, unknown>,
): void {
  const entry: ConnectLogEntry = { t: Date.now(), e };
  if (sid) entry.sid = sid;
  if (d && Object.keys(d).length > 0) entry.d = d;
  _buffer.push(entry);
  _prune();
  _write();
}

/** Read all entries, optionally filtered to last `maxAgeMs`. */
export function getConnectLog(maxAgeMs: number = MAX_AGE_MS): ConnectLogEntry[] {
  _prune();
  if (maxAgeMs >= MAX_AGE_MS) return [..._buffer];
  const cutoff = Date.now() - maxAgeMs;
  return _buffer.filter((e) => e.t >= cutoff);
}

/** Format an entry for human inspection (used by Settings + bug-report). */
export function formatConnectLogEntry(entry: ConnectLogEntry): string {
  const iso = new Date(entry.t).toISOString();
  const sid = entry.sid ? ` sid=${entry.sid.slice(-8)}` : '';
  const data = entry.d ? ` ${JSON.stringify(entry.d)}` : '';
  return `${iso} ${entry.e}${sid}${data}`;
}

/** Render the entire (24h-windowed) log as plain text. */
export function formatConnectLog(): string {
  return getConnectLog().map(formatConnectLogEntry).join('\n');
}

/** Wipe the log entirely. */
export function clearConnectLog(): void {
  _buffer = [];
  _write();
}

/** Trigger a browser download of the log as JSON. Filename includes the
 *  current ISO timestamp so multiple downloads don't collide. */
export function downloadConnectLog(): void {
  const ts = new Date().toISOString().replace(/[:.]/g, '-');
  const blob = new Blob([JSON.stringify(getConnectLog(), null, 2)], {
    type: 'application/json',
  });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `mobissh-connect-log-${ts}.json`;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => { URL.revokeObjectURL(url); }, 60_000);
}

/** Attached to bug reports — same as the JSON download but inline. */
export function getConnectLogForBugReport(): ConnectLogEntry[] {
  return getConnectLog();
}
