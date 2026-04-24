/**
 * notification-expiry.test.ts — TDD red baseline for #266
 *
 * Issue #266: notification badge shows stale count after expiry cleanup.
 *
 * These tests express EXPECTED behavior that is NOT yet implemented.
 * They will FAIL until the feature is built — this is intentional (TDD red phase).
 */

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

// Tracked DOM state
let sessionMenuBtnText = 'user@host';
let bellBadgeText = '0';
let bellBadgeClasses = new Set<string>(['hidden']);
let bellIndicatorBtnClasses = new Set<string>(['hidden']);

// Cached mock elements (reset each test)
let _sessionMenuBtnEl: Record<string, unknown> | null = null;

function makeMockElement(opts: {
  text?: string;
  classes?: Set<string>;
  innerHTML?: string;
  children?: Record<string, { text?: string; classes?: Set<string> }>;
}): Record<string, unknown> {
  // Parse a minimal <span class="X">Y</span> occurrence out of innerHTML.
  // Used to expose .session-title-text and .session-title-badge to querySelector.
  function extractSpanText(html: string, cls: string): string | null {
    const re = new RegExp(`<span class="${cls}">([^<]*)</span>`);
    const m = re.exec(html);
    return m ? m[1]! : null;
  }

  const el: Record<string, unknown> = {
    // textContent derives from innerHTML when present (matches browser semantics
    // for elements whose content was set via innerHTML), otherwise falls back
    // to opts.text.
    get textContent() {
      if (opts.innerHTML && opts.innerHTML.length > 0) {
        return opts.innerHTML.replace(/<[^>]+>/g, '');
      }
      return opts.text ?? '';
    },
    set textContent(v: string) { opts.text = v; opts.innerHTML = ''; },
    get innerHTML() { return opts.innerHTML ?? ''; },
    set innerHTML(v: string) { opts.innerHTML = v; },
    classList: {
      add: (...names: string[]) => { for (const n of names) opts.classes?.add(n); },
      remove: (...names: string[]) => { for (const n of names) opts.classes?.delete(n); },
      contains: (n: string) => opts.classes?.has(n) ?? false,
      toggle: (n: string, force?: boolean) => {
        const has = opts.classes?.has(n) ?? false;
        const shouldHave = force ?? !has;
        if (shouldHave) opts.classes?.add(n);
        else opts.classes?.delete(n);
        return shouldHave;
      },
    },
    querySelector: (sel: string) => {
      if (sel === '.bell-badge' && opts.children?.['bell-badge']) {
        const c = opts.children['bell-badge'];
        return {
          get textContent() { return c.text ?? ''; },
          set textContent(v: string) { c.text = v; },
          classList: {
            add: (...names: string[]) => { for (const n of names) c.classes?.add(n); },
            remove: (...names: string[]) => { for (const n of names) c.classes?.delete(n); },
            contains: (n: string) => c.classes?.has(n) ?? false,
            toggle: (n: string, force?: boolean) => {
              const has = c.classes?.has(n) ?? false;
              const shouldHave = force ?? !has;
              if (shouldHave) c.classes?.add(n);
              else c.classes?.delete(n);
              return shouldHave;
            },
          },
        };
      }
      // Synthesize a read-only view into the structured session-title spans (#458).
      if (sel === '.session-title-text' || sel === '.session-title-badge') {
        const cls = sel.slice(1);
        const text = extractSpanText(opts.innerHTML ?? '', cls);
        if (text === null) return null;
        return { textContent: text };
      }
      return null;
    },
    querySelectorAll: () => [],
    appendChild: vi.fn(),
    addEventListener: vi.fn(),
    dataset: {} as Record<string, string>,
    style: { width: '', height: '' },
  };
  return el;
}

function getElementById(id: string): unknown {
  switch (id) {
    case 'sessionMenuBtn':
      if (!_sessionMenuBtnEl) {
        _sessionMenuBtnEl = makeMockElement({
          text: sessionMenuBtnText,
          classes: new Set<string>(),
        }) as Record<string, unknown>;
      }
      return _sessionMenuBtnEl;
    case 'bellIndicatorBtn':
      return makeMockElement({
        text: '',
        classes: bellIndicatorBtnClasses,
        children: {
          'bell-badge': { text: bellBadgeText, classes: bellBadgeClasses },
        },
      });
    case 'notifDrawer':
      return makeMockElement({ classes: new Set<string>(['hidden']) });
    case 'notifDrawerList':
      return makeMockElement({ innerHTML: '' });
    default:
      return null;
  }
}

vi.stubGlobal('document', {
  getElementById: (id: string) => getElementById(id),
  querySelector: () => null,
  querySelectorAll: () => [],
  addEventListener: vi.fn(),
  visibilityState: 'visible',
  hasFocus: () => true,
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
    dataset: {},
    style: {},
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

// Import module under test
const {
  _addNotification,
  getNotifications,
  clearNotifications,
} = await import('../terminal.js');

// 30 minutes in ms (matches NOTIF_EXPIRY_MS in terminal.ts)
const THIRTY_MIN_MS = 30 * 60 * 1000;

function resetState(): void {
  clearNotifications();
  storage.clear();
  sessionMenuBtnText = 'user@host';
  _sessionMenuBtnEl = null;
  bellIndicatorBtnClasses = new Set<string>(['hidden']);
  bellBadgeText = '0';
  bellBadgeClasses = new Set<string>(['hidden']);
  vi.setSystemTime(new Date('2026-03-24T12:00:00Z'));
}

describe('#266: notification expiry cleanup updates badge', () => {
  beforeEach(() => {
    resetState();
  });

  it('notifications expire after 30 minutes — getNotifications returns empty', () => {
    _addNotification('deploy started');
    expect(getNotifications()).toHaveLength(1);

    // Advance 31 minutes past expiry
    vi.advanceTimersByTime(THIRTY_MIN_MS + 60_000);

    const remaining = getNotifications();
    expect(remaining).toHaveLength(0);
  });

  it('badge count updates after expiry — session title count is removed', () => {
    _addNotification('build complete');
    _addNotification('tests passed');

    // Session title should show count in the structured badge span (#458).
    const btnBefore = getElementById('sessionMenuBtn') as {
      querySelector: (sel: string) => { textContent: string } | null;
    };
    const badgeBefore = btnBefore.querySelector('.session-title-badge');
    expect(badgeBefore?.textContent).toBe('2');

    // Advance past expiry
    vi.advanceTimersByTime(THIRTY_MIN_MS + 60_000);

    // Trigger expiry cleanup
    getNotifications();

    // Session title should no longer show a count (badge span absent).
    const btnAfter = getElementById('sessionMenuBtn') as {
      querySelector: (sel: string) => { textContent: string } | null;
    };
    expect(btnAfter.querySelector('.session-title-badge')).toBeNull();
    expect(btnAfter.querySelector('.session-title-text')?.textContent).toBe('user@host');
  });

  it('partial expiry — only expired notifications are removed', () => {
    // Add first notification at t=0
    _addNotification('notification one');

    // Advance 10 minutes then add second
    vi.advanceTimersByTime(10 * 60 * 1000);
    _addNotification('notification two');

    // Advance 5 more minutes then add third
    vi.advanceTimersByTime(5 * 60 * 1000);
    _addNotification('notification three');

    expect(getNotifications()).toHaveLength(3);

    // Advance to 31 minutes after the first notification (16 minutes from now)
    // First was at t=0, now at t=15min, need 16 more minutes to reach t=31min
    vi.advanceTimersByTime(16 * 60 * 1000);

    // First notification should be expired, second and third still valid
    const remaining = getNotifications();
    expect(remaining).toHaveLength(2);
    expect(remaining[0]!.message).toBe('notification two');
    expect(remaining[1]!.message).toBe('notification three');
  });

  it('_updateBellBadge called after expiry cleanup — badge reflects current count', () => {
    _addNotification('alert one');
    _addNotification('alert two');
    _addNotification('alert three');

    // Session title should show "3" in the structured badge span (#458).
    const btn = getElementById('sessionMenuBtn') as {
      querySelector: (sel: string) => { textContent: string } | null;
    };
    expect(btn.querySelector('.session-title-badge')?.textContent).toBe('3');

    // Advance past expiry for all three
    vi.advanceTimersByTime(THIRTY_MIN_MS + 60_000);

    // getNotifications triggers cleanup and _updateBellBadge
    const remaining = getNotifications();
    expect(remaining).toHaveLength(0);

    // Session title should reflect zero notifications (badge span absent).
    expect(btn.querySelector('.session-title-badge')).toBeNull();
    expect(btn.querySelector('.session-title-text')?.textContent).toBe('user@host');
  });
});
