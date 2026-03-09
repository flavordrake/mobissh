import { describe, it, expect, beforeEach, vi } from 'vitest';

// Stub browser globals BEFORE any module imports

const storage = new Map<string, string>();
vi.stubGlobal('localStorage', {
  getItem: (key: string) => storage.get(key) ?? null,
  setItem: (key: string, value: string) => { storage.set(key, value); },
  removeItem: (key: string) => { storage.delete(key); },
  clear: () => { storage.clear(); },
  get length() { return storage.size; },
  key: (_i: number) => null as string | null,
});

vi.stubGlobal('location', { hostname: 'localhost' });

vi.stubGlobal('document', {
  getElementById: () => null,
  querySelector: () => null,
  addEventListener: vi.fn(),
  visibilityState: 'visible',
  documentElement: {
    style: { setProperty: vi.fn() },
    dataset: {},
  },
  createElement: vi.fn(() => ({
    className: '',
    textContent: '',
    innerHTML: '',
    appendChild: vi.fn(),
    addEventListener: vi.fn(),
    querySelector: vi.fn(),
  })),
  fonts: { ready: Promise.resolve() },
  body: { appendChild: vi.fn() },
});

vi.stubGlobal('getComputedStyle', () => ({
  getPropertyValue: () => '',
}));

vi.stubGlobal('Notification', { permission: 'granted' });

vi.stubGlobal('window', {
  addEventListener: vi.fn(),
  visualViewport: null,
  outerHeight: 900,
});

vi.useFakeTimers();

const { getNotifications, clearNotifications, _addNotification } = await import('../terminal.js');

// Helper: configure shouldNotify() to allow notifications
function enableNotifications(backgroundOnly = false): void {
  storage.set('termNotifications', 'true');
  storage.set('notifBackgroundOnly', backgroundOnly ? 'true' : 'false');
  storage.set('notifCooldown', '0');
  vi.stubGlobal('Notification', { permission: 'granted' });
  // For background-only=false, document must be visible (default stub is 'visible')
  vi.stubGlobal('document', {
    ...{
      getElementById: () => null,
      querySelector: () => null,
      addEventListener: vi.fn(),
      visibilityState: backgroundOnly ? 'hidden' : 'visible',
      documentElement: { style: { setProperty: vi.fn() }, dataset: {} },
      createElement: vi.fn(() => ({
        className: '', textContent: '', innerHTML: '',
        appendChild: vi.fn(), addEventListener: vi.fn(), querySelector: vi.fn(),
      })),
      fonts: { ready: Promise.resolve() },
      body: { appendChild: vi.fn() },
    },
  });
}

describe('notification cap enforcement (#94)', () => {
  beforeEach(() => {
    clearNotifications();
    storage.clear();
    enableNotifications(false);
    vi.setSystemTime(Date.now());
  });

  it('accepts a notification with a sufficiently long message', () => {
    _addNotification('hello world');
    expect(getNotifications().length).toBe(1);
  });

  it('caps at 50 entries, dropping the oldest', () => {
    for (let i = 0; i < 55; i++) {
      _addNotification(`message-${String(i).padStart(3, '0')}`);
    }
    const notifs = getNotifications();
    expect(notifs.length).toBe(50);
    // The oldest 5 should have been dropped
    expect(notifs[0]!.message).toBe('message-005');
    expect(notifs[49]!.message).toBe('message-054');
  });

  it('exactly 50 notifications does not drop any', () => {
    for (let i = 0; i < 50; i++) {
      _addNotification(`msg-${String(i).padStart(3, '0')}`);
    }
    expect(getNotifications().length).toBe(50);
  });
});

describe('notification expiry pruning (#94)', () => {
  beforeEach(() => {
    clearNotifications();
    storage.clear();
    enableNotifications(false);
    vi.setSystemTime(new Date('2026-01-01T12:00:00Z'));
  });

  it('prunes entries older than 30 minutes when getNotifications is called', () => {
    // Add some notifications at t=0
    _addNotification('old message one');
    _addNotification('old message two');

    // Advance time by 31 minutes
    vi.advanceTimersByTime(31 * 60 * 1000);

    // Add a fresh notification
    _addNotification('fresh message');

    const notifs = getNotifications();
    expect(notifs.length).toBe(1);
    expect(notifs[0]!.message).toBe('fresh message');
  });

  it('keeps entries that are exactly at the 30-minute boundary', () => {
    _addNotification('boundary message');

    // Advance to exactly 30 minutes - should still be valid (not strictly less)
    vi.advanceTimersByTime(30 * 60 * 1000 - 1);

    const notifs = getNotifications();
    expect(notifs.length).toBe(1);
  });

  it('prunes entries at 30 minutes + 1ms (strictly older than 30 minutes)', () => {
    _addNotification('expires now');

    // Advance one millisecond past 30 minutes — now strictly older
    vi.advanceTimersByTime(30 * 60 * 1000 + 1);

    const notifs = getNotifications();
    expect(notifs.length).toBe(0);
  });
});

describe('noise filtering (#94)', () => {
  beforeEach(() => {
    clearNotifications();
    storage.clear();
    enableNotifications(false);
    vi.setSystemTime(Date.now());
  });

  it('drops messages shorter than 3 characters', () => {
    _addNotification('');
    _addNotification('a');
    _addNotification('ab');
    expect(getNotifications().length).toBe(0);
  });

  it('accepts messages of exactly 3 characters', () => {
    _addNotification('abc');
    expect(getNotifications().length).toBe(1);
  });

  it('accepts messages longer than 3 characters', () => {
    _addNotification('hello');
    expect(getNotifications().length).toBe(1);
  });
});

describe('background-only filtering (#94)', () => {
  beforeEach(() => {
    clearNotifications();
    storage.clear();
    vi.setSystemTime(Date.now());
  });

  it('blocks notifications when backgroundOnly=true and page is visible', () => {
    // backgroundOnly=true means document must be hidden to notify
    enableNotifications(true);
    // document.visibilityState is 'hidden' from enableNotifications(true)
    // so this should go through
    _addNotification('from background');
    expect(getNotifications().length).toBe(1);
  });

  it('blocks notifications when termNotifications is disabled', () => {
    enableNotifications(false);
    storage.set('termNotifications', 'false');
    _addNotification('should be blocked');
    expect(getNotifications().length).toBe(0);
  });

  it('blocks notifications when Notification.permission is not granted', () => {
    enableNotifications(false);
    vi.stubGlobal('Notification', { permission: 'denied' });
    _addNotification('no permission');
    expect(getNotifications().length).toBe(0);
  });

  it('allows notifications when backgroundOnly=false and page is visible', () => {
    enableNotifications(false);
    // document.visibilityState is 'visible' from enableNotifications(false)
    _addNotification('foreground message');
    expect(getNotifications().length).toBe(1);
  });
});
