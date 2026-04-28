/**
 * Keep-alive ongoing notification — lifecycle tests.
 *
 * Verifies the notification is shown when sessions are connected and the
 * setting is on, hidden when off or when no sessions are live, and that
 * permission/SW failure paths surface as user-facing errors instead of being
 * silently swallowed (per the user's "no fire-and-forget without a feedback
 * loop" rule).
 */
import { describe, it, expect, beforeEach, vi } from 'vitest';

const storage = new Map<string, string>();
vi.stubGlobal('localStorage', {
  getItem: (key: string) => storage.get(key) ?? null,
  setItem: (key: string, value: string) => { storage.set(key, value); },
  removeItem: (key: string) => { storage.delete(key); },
  clear: () => { storage.clear(); },
  get length() { return storage.size; },
  key: (_i: number) => null as string | null,
});

vi.stubGlobal('Notification', { permission: 'granted', requestPermission: vi.fn() });

const closedNotifs: string[] = [];
const mockShowNotification = vi.fn(() => Promise.resolve());
const mockGetNotifications = vi.fn(() => Promise.resolve([
  { tag: 'mobissh-keepalive', close: () => closedNotifs.push('mobissh-keepalive') },
]));

vi.stubGlobal('navigator', {
  serviceWorker: {
    ready: Promise.resolve({
      showNotification: mockShowNotification,
      getNotifications: mockGetNotifications,
    }),
  },
});

vi.stubGlobal('window', { addEventListener: vi.fn(), Notification: { permission: 'granted' } });
vi.stubGlobal('document', { addEventListener: vi.fn() });

const { appState } = await import('../state.js');
const {
  isKeepAliveEnabled, setKeepAliveEnabledStorage,
  refreshKeepAliveNotification, dismissKeepAliveNotification,
  verifyKeepAliveSupport, NOTIF_TAG, STORAGE_KEY,
} = await import('../keepalive-notification.js');

type StateLite = 'connected' | 'reconnecting' | 'disconnected' | 'idle' | 'closed';
type SessionLite = {
  id: string; state: StateLite;
  profile: { host: string; port: number; username: string };
  ws: null; _stateChangedAt: number;
};
function makeSession(id: string, host: string, user: string, state: StateLite): SessionLite {
  return {
    id, state, profile: { host, port: 22, username: user },
    ws: null, _stateChangedAt: Date.now(),
  };
}

beforeEach(() => {
  storage.clear();
  closedNotifs.length = 0;
  mockShowNotification.mockClear();
  mockGetNotifications.mockClear();
  appState.sessions.clear();
  (globalThis as { Notification: { permission: string } }).Notification.permission = 'granted';
});

describe('keepalive-notification', () => {
  it('storage round-trips the setting flag', () => {
    expect(isKeepAliveEnabled()).toBe(false);
    setKeepAliveEnabledStorage(true);
    expect(localStorage.getItem(STORAGE_KEY)).toBe('true');
    expect(isKeepAliveEnabled()).toBe(true);
    setKeepAliveEnabledStorage(false);
    expect(isKeepAliveEnabled()).toBe(false);
  });

  it('does nothing when the setting is off', async () => {
    appState.sessions.set('s1', makeSession('s1', 'h1', 'u1', 'connected') as never);
    await refreshKeepAliveNotification();
    expect(mockShowNotification).not.toHaveBeenCalled();
  });

  it('shows a single-session notification with user@host title', async () => {
    setKeepAliveEnabledStorage(true);
    appState.sessions.set('s1', makeSession('s1', 'spark.example', 'mafrazier', 'connected') as never);
    await refreshKeepAliveNotification();
    expect(mockShowNotification).toHaveBeenCalledOnce();
    const [title, opts] = mockShowNotification.mock.calls[0] as unknown as [string, Record<string, unknown>];
    expect(title).toBe('MobiSSH — mafrazier@spark.example');
    expect(opts.tag).toBe(NOTIF_TAG);
    expect(opts.silent).toBe(true);
    expect(opts.requireInteraction).toBe(true);
    expect(opts.actions).toEqual([{ action: 'disconnect-all', title: 'Disconnect all' }]);
  });

  it('shows a count + list when multiple sessions are connected', async () => {
    setKeepAliveEnabledStorage(true);
    appState.sessions.set('a', makeSession('a', 'h1', 'u1', 'connected') as never);
    appState.sessions.set('b', makeSession('b', 'h2', 'u2', 'reconnecting'));
    appState.sessions.set('c', makeSession('c', 'h3', 'u3', 'connected'));
    await refreshKeepAliveNotification();
    const [title, opts] = mockShowNotification.mock.calls[0] as unknown as [string, Record<string, unknown>];
    expect(title).toBe('MobiSSH — 3 sessions');
    expect(opts.body).toBe('u1@h1\nu2@h2\nu3@h3');
  });

  it('counts reconnecting sessions as alive (user expects them to come back)', async () => {
    setKeepAliveEnabledStorage(true);
    appState.sessions.set('a', makeSession('a', 'h1', 'u1', 'reconnecting') as never);
    await refreshKeepAliveNotification();
    expect(mockShowNotification).toHaveBeenCalledOnce();
  });

  it('dismisses when no sessions are live', async () => {
    setKeepAliveEnabledStorage(true);
    appState.sessions.set('a', makeSession('a', 'h1', 'u1', 'disconnected') as never);
    appState.sessions.set('b', makeSession('b', 'h2', 'u2', 'closed') as never);
    await refreshKeepAliveNotification();
    expect(mockShowNotification).not.toHaveBeenCalled();
    expect(mockGetNotifications).toHaveBeenCalled();
    expect(closedNotifs).toContain(NOTIF_TAG);
  });

  it('dismisses when the setting is turned off', async () => {
    appState.sessions.set('a', makeSession('a', 'h1', 'u1', 'connected') as never);
    setKeepAliveEnabledStorage(false);
    await dismissKeepAliveNotification();
    expect(closedNotifs).toContain(NOTIF_TAG);
  });

  it('does not show when notification permission is not granted', async () => {
    (globalThis as { Notification: { permission: string } }).Notification.permission = 'default';
    setKeepAliveEnabledStorage(true);
    appState.sessions.set('a', makeSession('a', 'h1', 'u1', 'connected') as never);
    await refreshKeepAliveNotification();
    expect(mockShowNotification).not.toHaveBeenCalled();
  });

  it('verifyKeepAliveSupport returns null when permission is granted', async () => {
    const err = await verifyKeepAliveSupport();
    expect(err).toBeNull();
  });

  it('verifyKeepAliveSupport surfaces denied permission as a user-facing error', async () => {
    (globalThis as { Notification: { permission: string } }).Notification.permission = 'denied';
    const err = await verifyKeepAliveSupport();
    expect(err).not.toBeNull();
    expect(err).toMatch(/denied/i);
  });
});
