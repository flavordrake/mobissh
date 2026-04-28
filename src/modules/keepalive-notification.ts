/**
 * Keep-alive ongoing notification (#478-class follow-up).
 *
 * Android Chrome aggressively suspends backgrounded tabs and kills WebSockets
 * (observed: ~480 code-1006 closures per 20h with no app-layer cause). The
 * documented platform escape hatch is a persistent "ongoing" notification —
 * it tells Android the tab is doing user-meaningful work, so the OS keeps the
 * tab alive instead of freezing/killing it.
 *
 * This module owns the lifecycle of a single replaceable notification tagged
 * `mobissh-keepalive`. It updates as sessions connect/disconnect and dismisses
 * itself when the last session goes away or when the user disables the setting.
 *
 * Failure modes the user must see (not silent):
 *   - Permission denied → caller surfaces via showErrorDialog
 *   - SW unavailable → setting cannot be enabled; toggle reverts
 *   - showNotification rejection → caller surfaces; setting reverts
 */
import { appState } from './state.js';

export const NOTIF_TAG = 'mobissh-keepalive';
export const STORAGE_KEY = 'keepAliveInBackground';

export function isKeepAliveEnabled(): boolean {
  return localStorage.getItem(STORAGE_KEY) === 'true';
}

export function setKeepAliveEnabledStorage(enabled: boolean): void {
  localStorage.setItem(STORAGE_KEY, enabled ? 'true' : 'false');
}

interface ConnectedSummary {
  count: number;
  label: string;
  body: string;
}

function summarize(): ConnectedSummary {
  const live: { user: string; host: string }[] = [];
  for (const s of appState.sessions.values()) {
    if (!s.profile) continue;
    // Anything that should hold the connection slot — including reconnecting,
    // since the user expects the session to come back.
    if (s.state === 'connected' || s.state === 'soft_disconnected'
        || s.state === 'reconnecting' || s.state === 'authenticating') {
      live.push({ user: s.profile.username, host: s.profile.host });
    }
  }
  if (live.length === 0) {
    return { count: 0, label: '', body: '' };
  }
  if (live.length === 1) {
    const only = live[0]!;
    return {
      count: 1,
      label: `MobiSSH — ${only.user}@${only.host}`,
      body: 'Session connected. Tap to open.',
    };
  }
  return {
    count: live.length,
    label: `MobiSSH — ${String(live.length)} sessions`,
    body: live.map((s) => `${s.user}@${s.host}`).join('\n'),
  };
}

let _refreshing = false;
let _pending = false;

/**
 * Show, update, or dismiss the keepalive notification based on current state.
 * Idempotent and coalesces concurrent calls.
 */
export async function refreshKeepAliveNotification(): Promise<void> {
  if (_refreshing) { _pending = true; return; }
  _refreshing = true;
  try {
    if (!('serviceWorker' in navigator)) return;

    if (!isKeepAliveEnabled() || Notification.permission !== 'granted') {
      await dismissKeepAliveNotification();
      return;
    }

    const summary = summarize();
    if (summary.count === 0) {
      await dismissKeepAliveNotification();
      return;
    }

    const reg = await navigator.serviceWorker.ready;
    // `ongoing` and `silent` are spec-extension fields. Cast through unknown
    // because TS lib.dom doesn't include them.
    const opts = {
      tag: NOTIF_TAG,
      body: summary.body,
      silent: true,
      requireInteraction: true,
      renotify: false,
      ongoing: true,
      actions: [{ action: 'disconnect-all', title: 'Disconnect all' }],
    } as unknown as NotificationOptions;
    await reg.showNotification(summary.label, opts);
  } finally {
    _refreshing = false;
    if (_pending) {
      _pending = false;
      void refreshKeepAliveNotification();
    }
  }
}

export async function dismissKeepAliveNotification(): Promise<void> {
  if (!('serviceWorker' in navigator)) return;
  try {
    const reg = await navigator.serviceWorker.ready;
    const notifs = await reg.getNotifications({ tag: NOTIF_TAG });
    for (const n of notifs) n.close();
  } catch {
    // ignore — best-effort dismissal
  }
}

/**
 * Verify the platform can host an ongoing notification before letting the user
 * enable the setting. Returns null on success, or a user-facing error string.
 *
 * Caller is responsible for surfacing the error and rolling back the toggle.
 */
export async function verifyKeepAliveSupport(): Promise<string | null> {
  if (!('Notification' in window)) {
    return 'Notifications not supported in this browser.';
  }
  if (!('serviceWorker' in navigator)) {
    return 'Service Worker not supported in this browser.';
  }
  if (Notification.permission === 'denied') {
    return 'Notification permission was denied. Re-enable it in your browser site settings, then try again.';
  }
  if (Notification.permission !== 'granted') {
    let result: NotificationPermission;
    try {
      result = await Notification.requestPermission();
    } catch (err) {
      return `Permission request failed: ${String(err)}`;
    }
    if (result !== 'granted') {
      return `Permission ${result}. Background keep-alive needs notification permission.`;
    }
  }
  try {
    await navigator.serviceWorker.ready;
  } catch (err) {
    return `Service worker not ready: ${String(err)}`;
  }
  return null;
}
