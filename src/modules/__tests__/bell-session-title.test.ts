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
    get textContent() {
      // If innerHTML is set with spans, derive text from it (#458).
      if (opts.innerHTML) return opts.innerHTML.replace(/<[^>]+>/g, '');
      return opts.text ?? '';
    },
    set textContent(v: string) { opts.text = v; opts.innerHTML = v; },
    get innerHTML() { return opts.innerHTML ?? ''; },
    set innerHTML(v: string) { opts.innerHTML = v; opts.text = v.replace(/<[^>]+>/g, ''); },
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
      // Parse .session-title-text / .session-title-badge spans from innerHTML (#458)
      if (sel === '.session-title-badge' || sel === '.session-title-text') {
        const cls = sel.slice(1);
        const html = String(opts.innerHTML ?? '');
        const re = new RegExp(`<span\\s+class="([^"]*\\b${cls}\\b[^"]*)"[^>]*>([^<]*)</span>`);
        const m = re.exec(html);
        if (!m) return null;
        return {
          get textContent() { return m[2] ?? ''; },
          get className() { return m[1] ?? ''; },
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

// Cache elements so state persists across getElementById calls (like real DOM)
let _sessionMenuBtnEl: Record<string, unknown> | null = null;
let _sessionMenuEl: Record<string, unknown> | null = null;

function getElementById(id: string): unknown {
  switch (id) {
    case 'sessionMenuBtn':
      if (!_sessionMenuBtnEl) {
        _sessionMenuBtnEl = makeMockElement({
          text: sessionMenuBtnText,
          classes: sessionMenuBtnClasses,
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
    case 'sessionMenu':
      if (!_sessionMenuEl) {
        _sessionMenuEl = makeMockElement({
          innerHTML: sessionMenuInnerHTML,
          classes: sessionMenuClasses,
        }) as Record<string, unknown>;
      }
      return _sessionMenuEl;
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
  _sessionMenuBtnEl = null; // Reset cached mocks so they pick up new text
  _sessionMenuEl = null;
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
    it('renders .session-title-badge span when notifications exist (#458)', () => {
      _addNotification('build started');
      _addNotification('build step 2');
      _addNotification('build complete');

      const btn = getElementById('sessionMenuBtn') as {
        querySelector: (s: string) => { textContent: string } | null;
      } | null;
      expect(btn).not.toBeNull();
      const badge = btn!.querySelector('.session-title-badge');
      expect(badge).not.toBeNull();
      expect(badge!.textContent).toBe('3');
    });

    it('shows no badge span when zero notifications (#458)', () => {
      const btn = getElementById('sessionMenuBtn') as {
        querySelector: (s: string) => { textContent: string } | null;
      } | null;
      expect(btn).not.toBeNull();
      expect(btn!.querySelector('.session-title-badge')).toBeNull();
    });

    it('badge textContent is "1" after a single notification (#458)', () => {
      _addNotification('single alert');
      const btn = getElementById('sessionMenuBtn') as {
        querySelector: (s: string) => { textContent: string } | null;
      } | null;
      const badge = btn!.querySelector('.session-title-badge');
      expect(badge).not.toBeNull();
      expect(badge!.textContent).toBe('1');
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
    it.skip('session menu contains a notification list section — deferred: menu injection caused layout issues on device', () => {
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
    it('badge textContent tracks notification count (#458)', () => {
      const q = (): { textContent: string } | null => {
        const b = getElementById('sessionMenuBtn') as {
          querySelector: (s: string) => { textContent: string } | null;
        } | null;
        return b?.querySelector('.session-title-badge') ?? null;
      };
      _addNotification('first');
      expect(q()!.textContent).toBe('1');
      _addNotification('second');
      expect(q()!.textContent).toBe('2');
      _addNotification('third');
      expect(q()!.textContent).toBe('3');
    });
  });

  describe('count clears on clearNotifications', () => {
    it('badge span disappears after clearNotifications() (#458)', () => {
      _addNotification('alert one');
      _addNotification('alert two');

      const q = (): unknown => {
        const b = getElementById('sessionMenuBtn') as {
          querySelector: (s: string) => unknown;
        } | null;
        return b?.querySelector('.session-title-badge') ?? null;
      };
      expect(q()).not.toBeNull();
      clearNotifications();
      expect(q()).toBeNull();
    });

    it('.session-title-text reverts to base label after clearing (#458)', () => {
      _addNotification('some alert');
      clearNotifications();
      const btn = getElementById('sessionMenuBtn') as {
        querySelector: (s: string) => { textContent: string } | null;
        textContent: string;
      } | null;
      const txt = btn!.querySelector('.session-title-text');
      const val = txt ? txt.textContent : btn!.textContent;
      expect(val).toBe('user@host');
    });
  });
});
