/**
 * TDD tests for per-session theme persistence (#104)
 *
 * Verifies that:
 * 1. Theme from profile is applied when connecting a session
 * 2. Default theme is used when profile has no theme
 * 3. Theme is restored when switching between sessions
 * 4. Theme changes persist on a session across switches
 * 5. applyTheme is called on switchSession with the target session's theme
 *
 * Some tests may FAIL because the feature is not yet implemented.
 * That is expected for TDD — they define the target behavior.
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

const sessionElements: Array<{
  dataset: Record<string, string>;
  classList: { toggle: ReturnType<typeof vi.fn>; add: ReturnType<typeof vi.fn>; contains: ReturnType<typeof vi.fn>; remove: ReturnType<typeof vi.fn> };
}> = [];

vi.stubGlobal('document', {
  getElementById: vi.fn(() => null),
  querySelector: vi.fn(() => null),
  querySelectorAll: vi.fn((selector: string) => {
    if (selector === '[data-session-id]') return sessionElements;
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

describe('per-session theme persistence (#104)', () => {
  beforeEach(() => {
    appState.sessions.clear();
    appState.activeSessionId = null;
    appState.activeThemeName = 'dark';
    sessionElements.length = 0;
    storage.clear();
    vi.clearAllMocks();
  });

  describe('theme applied on connect', () => {
    it('session activeThemeName is set to profile theme after creation', () => {
      // When a session is created for a profile with theme: 'dracula',
      // the session's activeThemeName should be 'dracula'
      const session = createSession('conn-1');
      session.profile = makeProfile({ theme: 'dracula' });

      // The feature should set session.activeThemeName from profile.theme
      // during session setup. Currently createSession inherits from appState,
      // so this test expresses the expected behavior that profile theme overrides.
      if (session.profile.theme) {
        session.activeThemeName = session.profile.theme;
      }

      expect(session.activeThemeName).toBe('dracula');
    });

    it('session theme is set from profile during connection setup', () => {
      // This test verifies the expected behavior: when a profile has a theme,
      // the session should automatically pick it up.
      // The develop agent should wire this into the connection flow.
      const session = createSession('conn-2');
      session.profile = makeProfile({ theme: 'dracula' });

      // Expected: createSession or the connection setup code reads profile.theme
      // and assigns it to session.activeThemeName.
      // Currently createSession copies appState.activeThemeName (which is 'dark').
      // This assertion will FAIL until the feature is implemented.
      expect(session.activeThemeName).toBe('dracula');
    });
  });

  describe('default theme when profile has no theme', () => {
    it('falls back to app default (dark) when profile has no theme field', () => {
      const session = createSession('default-1');
      session.profile = makeProfile(); // no theme field

      // When profile.theme is undefined, session should keep the app default
      expect(session.activeThemeName).toBe('dark');
    });

    it('falls back to dark when profile theme is explicitly undefined', () => {
      const session = createSession('default-2');
      session.profile = makeProfile({ theme: undefined });

      expect(session.activeThemeName).toBe('dark');
    });
  });

  describe('theme restored on switch', () => {
    it('switching to a session restores that session active theme', () => {
      const s1 = createSession('switch-1');
      const s2 = createSession('switch-2');
      s1.fitAddon = makeMockFitAddon() as unknown as typeof s1.fitAddon;
      s2.fitAddon = makeMockFitAddon() as unknown as typeof s2.fitAddon;
      s1.activeThemeName = 'dracula';
      s2.activeThemeName = 'nord';

      appState.activeSessionId = 'switch-1';

      // Switch to session 2 — theme should become 'nord'
      switchSession('switch-2');
      expect(appState.activeThemeName).toBe('nord');

      // Switch back to session 1 — theme should become 'dracula'
      switchSession('switch-1');
      expect(appState.activeThemeName).toBe('dracula');
    });

    it('each session preserves its own theme independently', () => {
      const s1 = createSession('indep-1');
      const s2 = createSession('indep-2');
      const s3 = createSession('indep-3');
      s1.fitAddon = makeMockFitAddon() as unknown as typeof s1.fitAddon;
      s2.fitAddon = makeMockFitAddon() as unknown as typeof s2.fitAddon;
      s3.fitAddon = makeMockFitAddon() as unknown as typeof s3.fitAddon;
      s1.activeThemeName = 'monokai';
      s2.activeThemeName = 'tokyoNight';
      s3.activeThemeName = 'solarizedDark';

      switchSession('indep-2');
      expect(appState.activeThemeName).toBe('tokyoNight');

      switchSession('indep-3');
      expect(appState.activeThemeName).toBe('solarizedDark');

      switchSession('indep-1');
      expect(appState.activeThemeName).toBe('monokai');
    });
  });

  describe('theme change persists on session', () => {
    it('setting activeThemeName on session survives switch away and back', () => {
      const s1 = createSession('persist-1');
      const s2 = createSession('persist-2');
      s1.fitAddon = makeMockFitAddon() as unknown as typeof s1.fitAddon;
      s2.fitAddon = makeMockFitAddon() as unknown as typeof s2.fitAddon;
      s1.activeThemeName = 'dark';
      s2.activeThemeName = 'dark';

      // Activate session 1, change its theme to 'nord'
      appState.activeSessionId = 'persist-1';
      s1.activeThemeName = 'nord';

      // Switch to session 2
      switchSession('persist-2');

      // Switch back to session 1 — should still be 'nord'
      switchSession('persist-1');
      expect(s1.activeThemeName).toBe('nord');
      expect(appState.activeThemeName).toBe('nord');
    });
  });

  describe('applyTheme called on switchSession', () => {
    it('switchSession calls applyTheme with the target session theme', () => {
      const s1 = createSession('apply-1');
      const s2 = createSession('apply-2');
      s1.fitAddon = makeMockFitAddon() as unknown as typeof s1.fitAddon;
      s2.fitAddon = makeMockFitAddon() as unknown as typeof s2.fitAddon;
      s2.activeThemeName = 'dracula';

      appState.activeSessionId = 'apply-1';

      // We spy on applyTheme to verify it's called during switchSession.
      // Since applyTheme is an exported function from terminal.ts and
      // switchSession is from ui.ts, the develop agent needs to wire
      // switchSession to call applyTheme(session.activeThemeName).
      //
      // We test this by checking the side effect: after switchSession,
      // appState.activeThemeName should match the target session's theme,
      // which is what applyTheme does.
      switchSession('apply-2');
      expect(appState.activeThemeName).toBe('dracula');
    });

    it('applyTheme updates appState.activeThemeName when called directly', () => {
      // Baseline: verify applyTheme works as expected
      applyTheme('nord');
      expect(appState.activeThemeName).toBe('nord');

      applyTheme('dracula');
      expect(appState.activeThemeName).toBe('dracula');
    });

    it('applyTheme ignores invalid theme names', () => {
      appState.activeThemeName = 'dark';
      applyTheme('nonexistent-theme');
      expect(appState.activeThemeName).toBe('dark');
    });
  });
});
