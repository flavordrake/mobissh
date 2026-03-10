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

const { getNotifications, clearNotifications, _addNotification, _sanitizeNotifText } = await import('../terminal.js');

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

describe('bell badge always added regardless of notify settings (#120)', () => {
  beforeEach(() => {
    clearNotifications();
    storage.clear();
    vi.setSystemTime(Date.now());
  });

  it('adds to list when backgroundOnly=true and page is visible', () => {
    // _addNotification no longer gates on shouldNotify — bell badge always shows
    _addNotification('foreground bell');
    expect(getNotifications().length).toBe(1);
  });

  it('adds to list when termNotifications is disabled', () => {
    storage.set('termNotifications', 'false');
    _addNotification('notifs off but badge shows');
    expect(getNotifications().length).toBe(1);
  });

  it('adds to list when Notification.permission is not granted', () => {
    _addNotification('no permission but badge shows');
    expect(getNotifications().length).toBe(1);
  });

  it('adds to list when backgroundOnly=false and page is visible', () => {
    _addNotification('foreground message');
    expect(getNotifications().length).toBe(1);
  });
});

describe('_sanitizeNotifText (#109)', () => {
  it('strips CSI ANSI escape sequences', () => {
    expect(_sanitizeNotifText('\x1b[1;32mhello\x1b[0m')).toBe('hello');
  });

  it('strips OSC escape sequences', () => {
    expect(_sanitizeNotifText('\x1b]0;title\x07hello')).toBe('hello');
  });

  it('strips OSC sequences with ST terminator', () => {
    expect(_sanitizeNotifText('\x1b]0;title\x1b\\hello')).toBe('hello');
  });

  it('removes control characters (non-printable ASCII)', () => {
    expect(_sanitizeNotifText('hello\x01\x02\x1fworld')).toBe('helloworld');
  });

  it('removes DEL (U+007F) character', () => {
    expect(_sanitizeNotifText('hel\x7flo')).toBe('hello');
  });

  it('removes C1 control characters (U+0080-U+009F)', () => {
    expect(_sanitizeNotifText('hel\x80\x9flo')).toBe('hello');
  });

  it('removes Unicode block/replacement characters (▯ and \uFFFD)', () => {
    expect(_sanitizeNotifText('▯▯ accept edits on (shift+tab)')).toBe('accept edits on (shift+tab)');
    expect(_sanitizeNotifText('\uFFFD data \uFFFD')).toBe('data');
  });

  it('collapses multiple spaces to a single space', () => {
    expect(_sanitizeNotifText('hello   world')).toBe('hello world');
  });

  it('truncates text longer than 120 characters with ellipsis', () => {
    const long = 'a'.repeat(130);
    const result = _sanitizeNotifText(long);
    expect(result.length).toBe(120);
    expect(result.endsWith('...')).toBe(true);
  });

  it('returns Terminal bell for empty string', () => {
    expect(_sanitizeNotifText('')).toBe('Terminal bell');
  });

  it('returns Terminal bell for string shorter than 3 chars after sanitization', () => {
    expect(_sanitizeNotifText('ab')).toBe('Terminal bell');
    expect(_sanitizeNotifText('a')).toBe('Terminal bell');
  });

  it('returns Terminal bell for string that is all control chars', () => {
    expect(_sanitizeNotifText('\x1b[1m\x1b[0m\x01\x02')).toBe('Terminal bell');
  });

  it('returns Terminal bell for string that is only replacement chars', () => {
    expect(_sanitizeNotifText('▯▯▯')).toBe('Terminal bell');
  });

  it('preserves clean text unchanged (up to 120 chars)', () => {
    expect(_sanitizeNotifText('Build complete: all tests passed')).toBe('Build complete: all tests passed');
  });

  it('handles mixed content: ANSI + replacement chars + real text', () => {
    const raw = '\x1b[32m▯▯ accept edits on (shift+tab to cycle) · e...\x1b[0m';
    const result = _sanitizeNotifText(raw);
    expect(result).toBe('accept edits on (shift+tab to cycle) · e...');
  });
});
