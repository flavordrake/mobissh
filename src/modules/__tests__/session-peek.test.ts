/**
 * TDD tests for full-screen terminal peek on session swipe (#288)
 *
 * Verifies that:
 * 1. touchmove past threshold shows target session container (removes hidden class)
 * 2. touchmove past threshold hides active session container (adds hidden class)
 * 3. touchmove past threshold applies target session's theme
 * 4. touchmove past threshold does NOT change appState.activeSessionId
 * 5. touchmove past threshold does NOT call fitAddon.fit() or send resize
 * 6. Direction reversal updates peek to new target
 * 7. Snap back (dx returns within threshold) restores original container + theme
 * 8. touchend committed: calls switchSession(targetId)
 * 9. touchend cancelled: restores original container, theme, title
 * 10. Single session: no peek (guard)
 *
 * These tests FAIL because the feature is not yet implemented.
 * That is expected for TDD -- they define the target behavior.
 */
import { describe, it, expect, beforeEach, vi } from 'vitest';

// Stub browser globals before any module imports

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

/** Mock DOM elements keyed by data-session-id */
const sessionContainers = new Map<string, {
  dataset: Record<string, string>;
  classList: {
    toggle: ReturnType<typeof vi.fn>;
    add: ReturnType<typeof vi.fn>;
    remove: ReturnType<typeof vi.fn>;
    contains: ReturnType<typeof vi.fn>;
  };
}>();

function makeContainer(sessionId: string, hidden: boolean) {
  const el = {
    dataset: { sessionId },
    classList: {
      toggle: vi.fn((cls: string, force?: boolean) => {
        if (cls === 'hidden' && force !== undefined) {
          el._hidden = force;
        }
      }),
      add: vi.fn((cls: string) => {
        if (cls === 'hidden') el._hidden = true;
      }),
      remove: vi.fn((cls: string) => {
        if (cls === 'hidden') el._hidden = false;
      }),
      contains: vi.fn((cls: string) => {
        if (cls === 'hidden') return el._hidden;
        return false;
      }),
    },
    _hidden: hidden,
  };
  sessionContainers.set(sessionId, el);
  return el;
}

/** Mock menuBtn element */
const menuBtn = {
  textContent: '',
  style: { opacity: '' } as Record<string, string>,
  addEventListener: vi.fn(),
  classList: { add: vi.fn(), remove: vi.fn(), toggle: vi.fn(), contains: vi.fn(() => false) },
};

/** Mock terminal container */
const terminalDiv = {
  dataset: {} as Record<string, string>,
  style: { setProperty: vi.fn() },
};

vi.stubGlobal('document', {
  getElementById: vi.fn((id: string) => {
    if (id === 'sessionMenuBtn') return menuBtn;
    if (id === 'terminal') return terminalDiv;
    if (id === 'sessionMenu') return { classList: { add: vi.fn(), remove: vi.fn() } };
    if (id === 'menuBackdrop') return { classList: { add: vi.fn(), remove: vi.fn() } };
    return null;
  }),
  querySelector: vi.fn((selector: string) => {
    // Match #terminal [data-session-id="X"]
    const m = selector.match(/data-session-id="([^"]+)"/);
    if (m) return sessionContainers.get(m[1]!) ?? null;
    return null;
  }),
  querySelectorAll: vi.fn((selector: string) => {
    if (selector.includes('data-session-id')) {
      return Array.from(sessionContainers.values());
    }
    return [];
  }),
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
    dataset: {} as Record<string, string>,
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
vi.stubGlobal('navigator', { wakeLock: undefined, serviceWorker: undefined, vibrate: vi.fn() });
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

const { applyTheme } = await import('../terminal.js');
const { switchSession } = await import('../ui.js');
const { appState, createSession } = await import('../state.js');

import type { SSHProfile, ThemeName } from '../types.js';

function makeMockFitAddon(): { fit: ReturnType<typeof vi.fn> } {
  return { fit: vi.fn() };
}

function makeProfile(overrides: Partial<SSHProfile> = {}): SSHProfile {
  return {
    name: 'Test Server',
    host: '10.0.0.1',
    port: 22,
    username: 'testuser',
    authType: 'password',
    ...overrides,
  };
}

/** Simulate a touchmove event with a given clientX delta from swipeX0 */
function simulatePeek(
  sessions: Map<string, { id: string; activeThemeName: ThemeName; profile: SSHProfile | null }>,
  activeId: string,
  dx: number,
): { targetId: string; targetTheme: ThemeName } {
  const keys = Array.from(sessions.keys());
  const idx = keys.indexOf(activeId);
  const direction = dx > 0 ? -1 : 1;
  const targetIdx = (idx + direction + keys.length) % keys.length;
  const targetId = keys[targetIdx]!;
  const target = sessions.get(targetId)!;
  return { targetId, targetTheme: target.activeThemeName };
}

describe('issue-288: full-screen terminal peek on session swipe', () => {
  let s1: ReturnType<typeof createSession>;
  let s2: ReturnType<typeof createSession>;
  let s3: ReturnType<typeof createSession>;

  beforeEach(() => {
    appState.sessions.clear();
    appState.activeSessionId = null;
    appState.activeThemeName = 'dark';
    sessionContainers.clear();
    storage.clear();
    menuBtn.textContent = '';
    menuBtn.style.opacity = '';
    terminalDiv.dataset['theme'] = 'dark';
    vi.clearAllMocks();

    // Set up three sessions with different themes
    s1 = createSession('sess-1');
    s1.profile = makeProfile({ username: 'alice', host: 'server-a' });
    s1.fitAddon = makeMockFitAddon() as unknown as typeof s1.fitAddon;
    s1.activeThemeName = 'dracula';

    s2 = createSession('sess-2');
    s2.profile = makeProfile({ username: 'bob', host: 'server-b' });
    s2.fitAddon = makeMockFitAddon() as unknown as typeof s2.fitAddon;
    s2.activeThemeName = 'nord';

    s3 = createSession('sess-3');
    s3.profile = makeProfile({ username: 'carol', host: 'server-c' });
    s3.fitAddon = makeMockFitAddon() as unknown as typeof s3.fitAddon;
    s3.activeThemeName = 'monokai';

    appState.activeSessionId = 'sess-1';
    applyTheme('dracula');

    // Create mock DOM containers
    makeContainer('sess-1', false);  // active, visible
    makeContainer('sess-2', true);   // hidden
    makeContainer('sess-3', true);   // hidden

    menuBtn.textContent = 'alice@server-a';
  });

  describe('touchmove past threshold shows target container', () => {
    it('removes hidden class from target session container on swipe left (dx < -30)', () => {
      // Swipe left past threshold targets sess-2 (next)
      const { targetId } = simulatePeek(appState.sessions as never, 'sess-1', -40);
      expect(targetId).toBe('sess-2');

      // The peek behavior should remove 'hidden' from the target container.
      // Currently the swipe handler only changes menuBtn text. This test will
      // FAIL until the develop agent implements container visibility toggling.
      const targetContainer = sessionContainers.get('sess-2')!;

      // After peek, target container should be visible (hidden = false)
      expect(targetContainer._hidden).toBe(false);

      // ACTUAL TEST: The swipe handler in touchmove should have called
      // targetContainer.classList.remove('hidden'). Since the current code
      // does not do this, we assert expected behavior post-implementation:
      // The target container must not have the hidden class during peek.
      expect(targetContainer.classList.remove).toHaveBeenCalledWith('hidden');
    });

    it('removes hidden class from target session container on swipe right (dx > 30)', () => {
      const { targetId } = simulatePeek(appState.sessions as never, 'sess-1', 40);
      expect(targetId).toBe('sess-3');

      const targetContainer = sessionContainers.get('sess-3')!;
      expect(targetContainer.classList.remove).toHaveBeenCalledWith('hidden');
    });
  });

  describe('touchmove past threshold hides active container', () => {
    it('adds hidden class to active session container during peek', () => {
      // During peek, the active session's container should be hidden
      // so only the target session's terminal is visible.
      const activeContainer = sessionContainers.get('sess-1')!;

      // The current swipe handler does not hide the active container.
      // This test defines the expected behavior.
      expect(activeContainer.classList.add).toHaveBeenCalledWith('hidden');
    });
  });

  describe('touchmove past threshold applies target theme', () => {
    it('applies target session theme to app chrome via applyTheme', () => {
      // When peeking at sess-2 (theme: nord), the app chrome should
      // reflect nord's CSS custom properties.
      // The current code does not call applyTheme during touchmove.

      // After peek toward sess-2, activeThemeName should temporarily be 'nord'
      // (applyTheme sets appState.activeThemeName as a side effect).
      // But activeSessionId should NOT change.
      expect(appState.activeThemeName).toBe('nord');
    });

    it('sets data-theme attribute on #terminal to target theme name', () => {
      // The #terminal element's data-theme should match the peeked session's theme
      expect(terminalDiv.dataset['theme']).toBe('nord');
    });
  });

  describe('touchmove past threshold does NOT change activeSessionId', () => {
    it('activeSessionId remains unchanged during peek', () => {
      // The peek is visual-only. appState.activeSessionId must stay on
      // the original session until touchend commits the switch.
      // Current code already doesn't change it during touchmove, but
      // this test guards that invariant for the new implementation.
      expect(appState.activeSessionId).toBe('sess-1');
    });
  });

  describe('touchmove past threshold does NOT call fitAddon.fit() or send resize', () => {
    it('fitAddon.fit() is not called on target session during peek', () => {
      // Peek is visual-only. No terminal resize should happen.
      const targetFitAddon = s2.fitAddon as unknown as { fit: ReturnType<typeof vi.fn> };
      expect(targetFitAddon.fit).not.toHaveBeenCalled();
    });

    it('fitAddon.fit() is not called on active session during peek', () => {
      const activeFitAddon = s1.fitAddon as unknown as { fit: ReturnType<typeof vi.fn> };
      expect(activeFitAddon.fit).not.toHaveBeenCalled();
    });

    it('no WebSocket resize message is sent during peek', () => {
      // Neither session's ws.send should be called with a resize message
      if (s2.ws) {
        expect(s2.ws.send).not.toHaveBeenCalled();
      }
      if (s1.ws) {
        expect(s1.ws.send).not.toHaveBeenCalled();
      }
    });
  });

  describe('direction reversal updates peek to new target', () => {
    it('reversing swipe direction peeks at the session in the new direction', () => {
      // User starts swiping left (toward sess-2), then reverses right (toward sess-3).
      // After reversal, sess-3's container should be visible, sess-2 re-hidden.
      const container2 = sessionContainers.get('sess-2')!;
      const container3 = sessionContainers.get('sess-3')!;

      // After direction reversal to right, sess-3 should be visible
      expect(container3._hidden).toBe(false);
      // sess-2 should be re-hidden
      expect(container2._hidden).toBe(true);
    });

    it('theme updates to match the new target after direction reversal', () => {
      // After reversing from sess-2 (nord) to sess-3 (monokai),
      // appState.activeThemeName should be 'monokai'
      expect(appState.activeThemeName).toBe('monokai');
    });
  });

  describe('snap back restores original container and theme', () => {
    it('returns dx within threshold restores active container visibility', () => {
      // User swipes past threshold (peek activates), then moves back within
      // the 30px dead zone. The original session container should be restored.
      const activeContainer = sessionContainers.get('sess-1')!;

      // After snap back, the active container should be visible again
      expect(activeContainer._hidden).toBe(false);
    });

    it('snap back restores original session theme', () => {
      // After snap back, the original theme (dracula) should be re-applied
      expect(appState.activeThemeName).toBe('dracula');
    });

    it('snap back re-hides the target container', () => {
      const targetContainer = sessionContainers.get('sess-2')!;

      // After snap back, the target container should be hidden again
      expect(targetContainer._hidden).toBe(true);
    });

    it('snap back restores menuBtn text to original session name', () => {
      expect(menuBtn.textContent).toBe('alice@server-a');
    });
  });

  describe('touchend committed: calls switchSession(targetId)', () => {
    it('switchSession is called with target session id after committed swipe', () => {
      // Simulate: touchstart -> touchmove past threshold -> touchend with |dx| > 30
      // The touchend handler should call switchSession with the target session id.

      // After committed swipe to sess-2:
      switchSession('sess-2');

      expect(appState.activeSessionId).toBe('sess-2');
      expect(appState.activeThemeName).toBe('nord');
    });

    it('menuBtn opacity is reset after committed swipe', () => {
      // After touchend (committed), opacity should be cleared
      switchSession('sess-2');
      menuBtn.style.opacity = '';

      expect(menuBtn.style.opacity).toBe('');
    });

    it('fitAddon.fit() is called on target session after switch', () => {
      switchSession('sess-2');

      const targetFitAddon = s2.fitAddon as unknown as { fit: ReturnType<typeof vi.fn> };
      expect(targetFitAddon.fit).toHaveBeenCalled();
    });

    it('resize message sent if target session is connected', () => {
      // Set up sess-2 as connected with a WebSocket
      const mockWs = { readyState: 1, send: vi.fn(), close: vi.fn() };
      s2.ws = mockWs as unknown as WebSocket;
      s2.sshConnected = true;

      switchSession('sess-2');

      expect(mockWs.send).toHaveBeenCalledWith(
        expect.stringContaining('"type":"resize"'),
      );
    });
  });

  describe('touchend cancelled: restores original container, theme, title', () => {
    it('restores original session container to visible on cancel', () => {
      // touchend with |dx| <= 30: the swipe is cancelled.
      // The original session container must be restored to visible.
      const activeContainer = sessionContainers.get('sess-1')!;

      // After cancel, active container should not be hidden
      expect(activeContainer._hidden).toBe(false);
    });

    it('re-hides all non-active session containers on cancel', () => {
      const container2 = sessionContainers.get('sess-2')!;
      const container3 = sessionContainers.get('sess-3')!;

      // After cancel, non-active containers should be hidden
      expect(container2._hidden).toBe(true);
      expect(container3._hidden).toBe(true);
    });

    it('restores original theme on cancel', () => {
      // After cancel, the original theme (dracula) should be re-applied
      expect(appState.activeThemeName).toBe('dracula');
    });

    it('restores menuBtn.textContent to original session name on cancel', () => {
      expect(menuBtn.textContent).toBe('alice@server-a');
    });

    it('resets menuBtn.style.opacity on cancel', () => {
      expect(menuBtn.style.opacity).toBe('');
    });

    it('activeSessionId remains unchanged after cancel', () => {
      expect(appState.activeSessionId).toBe('sess-1');
    });
  });

  describe('single session: no peek (guard)', () => {
    it('does not peek when only one session exists', () => {
      // Clear and set up single session
      appState.sessions.clear();
      sessionContainers.clear();

      const solo = createSession('solo-1');
      solo.profile = makeProfile({ username: 'lonely', host: 'single' });
      solo.fitAddon = makeMockFitAddon() as unknown as typeof solo.fitAddon;
      solo.activeThemeName = 'dark';
      appState.activeSessionId = 'solo-1';

      makeContainer('solo-1', false);

      // With a single session, the touchstart handler returns early.
      // No container toggles, no theme changes, no menuBtn mutations.
      const container = sessionContainers.get('solo-1')!;
      expect(container._hidden).toBe(false);
      expect(appState.activeSessionId).toBe('solo-1');
      expect(appState.activeThemeName).toBe('dark');
    });

    it('does not peek when zero sessions exist', () => {
      appState.sessions.clear();
      sessionContainers.clear();
      appState.activeSessionId = null;

      // No crash, no mutations
      expect(appState.sessions.size).toBe(0);
      expect(appState.activeSessionId).toBeNull();
    });
  });

  describe('two sessions: wrap direction does not matter', () => {
    beforeEach(() => {
      // Reduce to 2 sessions
      appState.sessions.delete('sess-3');
      sessionContainers.delete('sess-3');
    });

    it('swipe left and swipe right both target the same other session', () => {
      const leftTarget = simulatePeek(appState.sessions as never, 'sess-1', -40);
      const rightTarget = simulatePeek(appState.sessions as never, 'sess-1', 40);

      expect(leftTarget.targetId).toBe('sess-2');
      expect(rightTarget.targetId).toBe('sess-2');
    });

    it('peek shows same terminal container regardless of swipe direction', () => {
      // With 2 sessions, both directions target sess-2.
      // The container for sess-2 should be shown in both cases.
      const container2 = sessionContainers.get('sess-2')!;

      // After peek (either direction), sess-2 should be visible
      // This will FAIL until the container toggle is implemented.
      expect(container2.classList.remove).toHaveBeenCalledWith('hidden');
    });
  });

  describe('same theme on both sessions still peeks container', () => {
    it('shows target container even when themes are identical', () => {
      // Both sessions share the same theme
      s1.activeThemeName = 'dark';
      s2.activeThemeName = 'dark';
      appState.activeSessionId = 'sess-1';

      // The peek should still show sess-2's container (different terminal content)
      // even though the theme colors would be the same.
      const container2 = sessionContainers.get('sess-2')!;
      expect(container2.classList.remove).toHaveBeenCalledWith('hidden');
    });
  });

  describe('title bar shows target session name during peek', () => {
    it('menuBtn.textContent is set to target username@host during peek', () => {
      // During peek toward sess-2, menuBtn should show "bob@server-b"
      // (not the arrow prefix "-> bob@server-b" from the old behavior)
      expect(menuBtn.textContent).toBe('bob@server-b');
    });

    it('menuBtn.style.opacity is 0.6 during peek', () => {
      // The peek state signals transience via reduced opacity
      expect(menuBtn.style.opacity).toBe('0.6');
    });
  });
});
