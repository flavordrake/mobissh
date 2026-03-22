/**
 * bell-session-title.test.ts — TDD red baseline for #251
 *
 * Issue #251: Move notification bell count to session title text,
 * access notifications via session menu, remove separate bell icon.
 *
 * These tests express EXPECTED behavior that is NOT yet implemented.
 * They will FAIL until the feature is built — this is intentional (TDD red phase).
 */

import { describe, it, expect, beforeEach, vi } from 'vitest';

// ── DOM stubs ────────────────────────────────────────────────────────────────

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

// Tracked DOM elements — tests inspect these after calling notification APIs.
let sessionMenuBtnText = 'MobiSSH';
let sessionMenuBtnClasses = new Set<string>();

let bellIndicatorBtnClasses = new Set<string>(['hidden']);
let bellBadgeText = '0';
let bellBadgeClasses = new Set<string>(['hidden']);

let sessionMenuClasses = new Set<string>(['hidden']);
let sessionMenuInnerHTML = '';

// Factory for mock elements so getElementById returns interactive stubs.
function makeMockElement(opts: {
  text?: string;
  classes?: Set<string>;
  innerHTML?: string;
  children?: Record<string, { text?: string; classes?: Set<string> }>;
}): Record<string, unknown> {
  const el: Record<string, unknown> = {
    get textContent() { return opts.text ?? ''; },
    set textContent(v: string) { if (opts.text !== undefined) { /* stored externally */ } opts.text = v; },
    get innerHTML() { return opts.innerHTML ?? ''; },
    set innerHTML(v: string) { if (opts.innerHTML !== undefined) opts.innerHTML = v; },
    get className() { return Array.from(opts.classes ?? []).join(' '); },
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
      // For notification entries inside the session menu
      if (sel === '.notif-entry') return null;
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
      return makeMockElement({
        text: sessionMenuBtnText,
        classes: sessionMenuBtnClasses,
      });
    case 'bellIndicatorBtn':
      return makeMockElement({
        text: '',
        classes: bellIndicatorBtnClasses,
        children: {
          'bell-badge': { text: bellBadgeText, classes: bellBadgeClasses },
        },
      });
    case 'sessionMenu':
      return makeMockElement({
        innerHTML: sessionMenuInnerHTML,
        classes: sessionMenuClasses,
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

// ── Import module under test ─────────────────────────────────────────────────

const {
  _addNotification,
  getNotifications,
  clearNotifications,
} = await import('../terminal.js');

// ── Helpers ──────────────────────────────────────────────────────────────────

function resetState(): void {
  clearNotifications();
  storage.clear();
  sessionMenuBtnText = 'user@host';
  sessionMenuBtnClasses = new Set<string>(['connected']);
  bellIndicatorBtnClasses = new Set<string>(['hidden']);
  bellBadgeText = '0';
  bellBadgeClasses = new Set<string>(['hidden']);
  sessionMenuClasses = new Set<string>(['hidden']);
  sessionMenuInnerHTML = '';
  vi.setSystemTime(Date.now());
}

// ── Tests ────────────────────────────────────────────────────────────────────

describe('#251: notification count in session title', () => {
  beforeEach(() => {
    resetState();
  });

  describe('session title shows notification count', () => {
    it('includes count in parens when notifications exist, e.g. "user@host (3)"', () => {
      // After adding 3 notifications, the session menu button text should
      // include the count appended to the session title.
      _addNotification('build started');
      _addNotification('build step 2');
      _addNotification('build complete');

      // The feature should update #sessionMenuBtn text to include the count.
      // We re-query the element to get the updated text.
      const btn = getElementById('sessionMenuBtn') as { textContent: string } | null;
      expect(btn).not.toBeNull();
      // Expected format: "user@host (3)" — the count in parentheses
      expect(btn!.textContent).toMatch(/\(3\)/);
    });

    it('shows no count when zero notifications', () => {
      // With zero notifications, the session title should be plain (no parens).
      const btn = getElementById('sessionMenuBtn') as { textContent: string } | null;
      expect(btn).not.toBeNull();
      expect(btn!.textContent).not.toMatch(/\(\d+\)/);
    });

    it('shows count of 1 after a single notification', () => {
      _addNotification('single alert');
      const btn = getElementById('sessionMenuBtn') as { textContent: string } | null;
      expect(btn!.textContent).toMatch(/\(1\)/);
    });
  });

  describe('bell icon is hidden', () => {
    it('#bellIndicatorBtn has class hidden when notifications exist', () => {
      // After issue #251, the bell icon should ALWAYS be hidden —
      // notifications are indicated by the session title count instead.
      _addNotification('test notification');
      // Currently _updateBellBadge() removes .hidden when count > 0.
      // After #251, bellIndicatorBtn should stay hidden (or be removed from DOM).
      expect(bellIndicatorBtnClasses.has('hidden')).toBe(true);
    });

    it('#bellIndicatorBtn has class hidden with zero notifications', () => {
      // Bell icon should be hidden regardless of notification count.
      expect(bellIndicatorBtnClasses.has('hidden')).toBe(true);
    });
  });

  describe('notification list in session menu', () => {
    it('session menu contains a notification list section', () => {
      // When the session menu is rendered, it should include a notification
      // list area (e.g., a container with notification entries).
      // This tests that the DOM structure includes notification items
      // when notifications exist.
      _addNotification('deploy started');
      _addNotification('deploy finished');

      // After #251, opening the session menu should render notification entries.
      // The session menu HTML should contain notification content.
      // We check for a notification list container or entries in the menu.
      const menu = getElementById('sessionMenu') as { innerHTML: string } | null;
      expect(menu).not.toBeNull();
      // Expected: menu innerHTML includes notification entries when menu is opened.
      // Since the feature doesn't exist yet, this verifies the integration point.
      // The implementation should render notification entries into the session menu.
      const notifications = getNotifications();
      expect(notifications.length).toBe(2);
      // The menu should contain rendered notification content (this will fail
      // until the feature wires notification rendering into the session menu).
      expect(menu!.innerHTML).toContain('notif');
    });
  });

  describe('count updates on new notification', () => {
    it('session title count increments after _addNotification()', () => {
      _addNotification('first');
      let btn = getElementById('sessionMenuBtn') as { textContent: string } | null;
      expect(btn!.textContent).toMatch(/\(1\)/);

      _addNotification('second');
      btn = getElementById('sessionMenuBtn') as { textContent: string } | null;
      expect(btn!.textContent).toMatch(/\(2\)/);

      _addNotification('third');
      btn = getElementById('sessionMenuBtn') as { textContent: string } | null;
      expect(btn!.textContent).toMatch(/\(3\)/);
    });
  });

  describe('count clears on clearNotifications', () => {
    it('session title shows no count after clearNotifications()', () => {
      _addNotification('alert one');
      _addNotification('alert two');

      // Verify count is shown
      let btn = getElementById('sessionMenuBtn') as { textContent: string } | null;
      expect(btn!.textContent).toMatch(/\(2\)/);

      // Clear and verify count disappears
      clearNotifications();
      btn = getElementById('sessionMenuBtn') as { textContent: string } | null;
      expect(btn!.textContent).not.toMatch(/\(\d+\)/);
    });

    it('session title reverts to plain text after clearing', () => {
      _addNotification('some alert');
      clearNotifications();
      const btn = getElementById('sessionMenuBtn') as { textContent: string } | null;
      // Should be just the session label, no parenthetical count
      expect(btn!.textContent).toBe('user@host');
    });
  });
});
