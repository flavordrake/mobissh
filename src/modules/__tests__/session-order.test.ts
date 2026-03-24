/**
 * Unit tests for session list visual order stability (#290)
 *
 * Verifies that renderSessionList() maintains stable insertion order
 * across re-renders and after switchSession() calls. The session list
 * is backed by a Map (insertion-ordered), so the rendered HTML must
 * reflect that order consistently.
 */
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { webcrypto } from 'node:crypto';

// Stub browser globals before any module imports

vi.stubGlobal('crypto', webcrypto);

const storage = new Map<string, string>();
vi.stubGlobal('localStorage', {
  getItem: (key: string) => storage.get(key) ?? null,
  setItem: (key: string, value: string) => { storage.set(key, value); },
  removeItem: (key: string) => { storage.delete(key); },
  clear: () => { storage.clear(); },
  get length() { return storage.size; },
  key: (_i: number) => null as string | null,
});

vi.stubGlobal('location', { hostname: 'localhost', hash: '' });

// Capture innerHTML written to sessionList container
let sessionListHTML = '';
const mockSessionList = {
  id: 'sessionList',
  innerHTML: '',
  classList: { add: vi.fn(), remove: vi.fn(), toggle: vi.fn(), contains: vi.fn(() => false) },
  querySelectorAll: vi.fn(() => []),
};

// Intercept innerHTML writes to capture rendered output
Object.defineProperty(mockSessionList, 'innerHTML', {
  get() { return sessionListHTML; },
  set(v: string) { sessionListHTML = v; },
});

vi.stubGlobal('document', {
  getElementById: vi.fn((id: string) => {
    if (id === 'sessionList') return mockSessionList;
    return null;
  }),
  querySelector: vi.fn(() => null),
  querySelectorAll: vi.fn(() => []),
  addEventListener: vi.fn(),
  visibilityState: 'visible',
  hasFocus: vi.fn(() => true),
  createElement: vi.fn(() => ({
    className: '',
    textContent: '',
    innerHTML: '',
    id: '',
    appendChild: vi.fn(),
    addEventListener: vi.fn(),
    querySelector: vi.fn(),
    remove: vi.fn(),
    classList: { add: vi.fn(), remove: vi.fn(), toggle: vi.fn(), contains: vi.fn(() => false) },
    dataset: {} as Record<string, string>,
  })),
  body: { appendChild: vi.fn() },
  documentElement: {
    style: { setProperty: vi.fn() },
    dataset: {},
  },
  fonts: { ready: Promise.resolve() },
});

vi.stubGlobal('WebSocket', class MockWebSocket {
  onopen: ((ev: unknown) => void) | null = null;
  onclose: ((ev: unknown) => void) | null = null;
  onmessage: ((ev: unknown) => void) | null = null;
  onerror: ((ev: unknown) => void) | null = null;
  readyState = 1;
  url = 'ws://localhost:8081';
  close = vi.fn();
  send = vi.fn();
  static OPEN = 1;
});

vi.stubGlobal('Worker', class { onmessage = null; postMessage = vi.fn(); terminate = vi.fn(); });
vi.stubGlobal('navigator', { wakeLock: undefined, serviceWorker: undefined });
vi.stubGlobal('window', { addEventListener: vi.fn(), visualViewport: null, outerHeight: 800 });
vi.stubGlobal('Notification', { permission: 'default' });
vi.stubGlobal('performance', { now: vi.fn(() => 0) });
vi.stubGlobal('CSS', { escape: (s: string) => s });
vi.stubGlobal('requestAnimationFrame', (cb: () => void) => { cb(); return 1; });
vi.stubGlobal('cancelAnimationFrame', vi.fn());
vi.stubGlobal('getComputedStyle', vi.fn(() => ({ getPropertyValue: vi.fn(() => '48px') })));

vi.stubGlobal('Terminal', function TerminalMock() {
  return {
    open: vi.fn(),
    loadAddon: vi.fn(),
    onBell: vi.fn(),
    writeln: vi.fn(),
    write: vi.fn(),
    parser: { registerOscHandler: vi.fn() },
    options: {} as Record<string, unknown>,
    buffer: { active: { cursorY: 0, getLine: vi.fn() } },
    cols: 80,
    rows: 24,
    reset: vi.fn(),
    scrollToBottom: vi.fn(),
  };
});
vi.stubGlobal('FitAddon', { FitAddon: function FitAddonMock() { return { fit: vi.fn() }; } });
vi.stubGlobal('ClipboardAddon', { ClipboardAddon: vi.fn() });

const { renderSessionList, switchSession } = await import('../ui.js');
const { appState, createSession } = await import('../state.js');

// ── Helpers ──────────────────────────────────────────────────────────────────

/** Extract data-session-id values from rendered HTML in order. */
function extractSessionIds(): string[] {
  const regex = /data-session-id="([^"]+)"/g;
  const ids: string[] = [];
  let match: RegExpExecArray | null;
  while ((match = regex.exec(sessionListHTML)) !== null) {
    // Each session-item div has data-session-id, and each close button has data-close-id.
    // Only collect the first occurrence per pair (the div's data-session-id).
    ids.push(match[1]!);
  }
  // Filter to unique session IDs (each session appears twice: div + close button)
  const seen = new Set<string>();
  return ids.filter((id) => {
    if (seen.has(id)) return false;
    seen.add(id);
    return true;
  });
}

function resetState(): void {
  appState.sessions.clear();
  appState.activeSessionId = null;
  sessionListHTML = '';
}

// ── Tests ────────────────────────────────────────────────────────────────────

describe('session list visual order (#290)', () => {
  beforeEach(() => {
    resetState();
  });

  describe('sessions render in insertion order', () => {
    it('three sessions render in the order they were created', () => {
      createSession('alpha');
      createSession('beta');
      createSession('gamma');
      appState.activeSessionId = 'alpha';

      renderSessionList();

      const ids = extractSessionIds();
      expect(ids).toEqual(['alpha', 'beta', 'gamma']);
    });

    it('single session renders alone', () => {
      createSession('only');
      appState.activeSessionId = 'only';

      renderSessionList();

      const ids = extractSessionIds();
      expect(ids).toEqual(['only']);
    });

    it('five sessions maintain insertion order', () => {
      const names = ['s1', 's2', 's3', 's4', 's5'];
      for (const name of names) createSession(name);
      appState.activeSessionId = 's1';

      renderSessionList();

      expect(extractSessionIds()).toEqual(names);
    });
  });

  describe('order preserved after switchSession', () => {
    it('switching to a later session does not reorder the list', () => {
      createSession('first');
      createSession('second');
      createSession('third');
      appState.activeSessionId = 'first';

      renderSessionList();
      expect(extractSessionIds()).toEqual(['first', 'second', 'third']);

      // switchSession calls renderSessionList internally
      switchSession('third');

      expect(extractSessionIds()).toEqual(['first', 'second', 'third']);
      expect(appState.activeSessionId).toBe('third');
    });

    it('switching to the middle session preserves order', () => {
      createSession('a');
      createSession('b');
      createSession('c');
      appState.activeSessionId = 'a';

      switchSession('b');

      expect(extractSessionIds()).toEqual(['a', 'b', 'c']);
      expect(appState.activeSessionId).toBe('b');
    });

    it('switching back and forth preserves order', () => {
      createSession('x');
      createSession('y');
      createSession('z');
      appState.activeSessionId = 'x';

      switchSession('z');
      switchSession('x');
      switchSession('y');
      switchSession('z');
      switchSession('x');

      expect(extractSessionIds()).toEqual(['x', 'y', 'z']);
    });
  });

  describe('order preserved after re-render', () => {
    it('multiple renderSessionList calls produce identical order', () => {
      createSession('r1');
      createSession('r2');
      createSession('r3');
      appState.activeSessionId = 'r1';

      renderSessionList();
      const first = extractSessionIds();

      renderSessionList();
      const second = extractSessionIds();

      renderSessionList();
      const third = extractSessionIds();

      expect(first).toEqual(['r1', 'r2', 'r3']);
      expect(second).toEqual(first);
      expect(third).toEqual(first);
    });

    it('re-render after switchSession still preserves order', () => {
      createSession('p1');
      createSession('p2');
      createSession('p3');
      appState.activeSessionId = 'p1';

      renderSessionList();
      const before = extractSessionIds();

      switchSession('p3');
      // switchSession already calls renderSessionList, but call again explicitly
      renderSessionList();
      const after = extractSessionIds();

      expect(before).toEqual(['p1', 'p2', 'p3']);
      expect(after).toEqual(before);
    });

    it('active session marker does not affect order', () => {
      createSession('m1');
      createSession('m2');
      createSession('m3');
      appState.activeSessionId = 'm1';

      renderSessionList();
      // Verify m1 has active class
      expect(sessionListHTML).toContain('session-item active');

      switchSession('m2');
      const ids = extractSessionIds();
      expect(ids).toEqual(['m1', 'm2', 'm3']);

      // Verify the active marker moved but order is unchanged
      const activeMatch = sessionListHTML.match(/session-item active" data-session-id="([^"]+)"/);
      expect(activeMatch?.[1]).toBe('m2');
    });
  });
});
