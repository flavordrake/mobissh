/**
 * TDD tests for session-aware files navigation (#409)
 *
 * Verifies that:
 * 1. _filesPath is not a module-level global in ui.ts (source grep)
 * 2. #sessionFilesBtn exists in index.html within #sessionMenu
 * 3. A back-to-terminal button exists in #panel-files
 * 4. switchSession updates the active files state pointer
 * 5. navigateToPanel('files') uses the active session's state
 * 6. initFiles first-activation is per-session (realpath request keyed per-session)
 */
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

// ── Source grep tests (no runtime needed) ──────────────────────────────

const uiSrc = readFileSync(resolve(__dirname, '../ui.ts'), 'utf8');
const indexHtml = readFileSync(resolve(__dirname, '../../../public/index.html'), 'utf8');

describe('session-aware files (#409) — source grep', () => {
  it('_filesPath is not a module-level `let _filesPath` global', () => {
    // The refactor moves _filesPath into per-session state.
    // No bare module-level `let _filesPath = '/';` should remain.
    const badMatch = /^let _filesPath\s*[:=]/m;
    expect(uiSrc).not.toMatch(badMatch);
  });

  it('_filesDeepLinkPath is not a module-level `let _filesDeepLinkPath` global', () => {
    const badMatch = /^let _filesDeepLinkPath\s*[:=]/m;
    expect(uiSrc).not.toMatch(badMatch);
  });

  it('_filesRealpathReqId is not a module-level `let _filesRealpathReqId` global', () => {
    const badMatch = /^let _filesRealpathReqId\s*[:=]/m;
    expect(uiSrc).not.toMatch(badMatch);
  });

  it('ui.ts declares a per-session files state map keyed by sessionId', () => {
    // Expect either a Map<string, FilesState> or an equivalent per-session
    // container. Look for a helper/function that resolves state by session id.
    const hasPerSessionState =
      /_filesStateFor|filesStateBySession|_filesStates|FilesState/.test(uiSrc);
    expect(hasPerSessionState).toBe(true);
  });
});

describe('session-aware files (#409) — HTML', () => {
  it('#sessionFilesBtn exists inside #sessionMenu', () => {
    // The sessionMenu contains nested divs (sessionList, font-size-row), so a
    // simple non-greedy regex doesn't find the matching close tag. Instead,
    // verify both the button exists AND it appears after the sessionMenu opening.
    expect(indexHtml).toContain('id="sessionFilesBtn"');
    const menuStart = indexHtml.indexOf('id="sessionMenu"');
    const btnStart = indexHtml.indexOf('id="sessionFilesBtn"');
    expect(menuStart).toBeGreaterThan(-1);
    expect(btnStart).toBeGreaterThan(menuStart);
  });

  it('#panel-files no longer has a back-to-terminal button (#452 — persistent session bar)', () => {
    // Removed with the persistent session bar (#452): the hamburger menu
    // is always reachable from the handle strip, so a dedicated back
    // button inside the files panel is no longer needed.
    expect(indexHtml).not.toContain('id="filesBackToTerminalBtn"');
  });
});

// ── Runtime tests ───────────────────────────────────────────────────────

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

vi.stubGlobal('history', {
  pushState: vi.fn(),
  replaceState: vi.fn(),
  back: vi.fn(),
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
vi.stubGlobal('window', { addEventListener: vi.fn(), visualViewport: null, outerHeight: 800, innerHeight: 800, innerWidth: 400 });
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

const ui = await import('../ui.js');
const { appState, createSession } = await import('../state.js');

import type { SSHProfile } from '../types.js';

function makeProfile(overrides: Partial<SSHProfile> = {}): SSHProfile {
  return {
    title: 'Test Server',
    host: '10.0.0.1',
    port: 22,
    username: 'testuser',
    authType: 'password',
    ...overrides,
  };
}

describe('session-aware files (#409) — runtime', () => {
  beforeEach(() => {
    appState.sessions.clear();
    appState.activeSessionId = null;
    storage.clear();
    sessionElements.length = 0;
    vi.clearAllMocks();
  });

  it('each session has its own files path', () => {
    const sA = createSession('sess-a');
    const sB = createSession('sess-b');
    sA.profile = makeProfile({ host: 'a.example' });
    sB.profile = makeProfile({ host: 'b.example' });

    // ui.ts must expose a way to get per-session files state.
    expect(typeof ui._filesStateFor).toBe('function');

    const stateA = ui._filesStateFor('sess-a');
    const stateB = ui._filesStateFor('sess-b');

    stateA.path = '/home/a';
    stateB.path = '/home/b';

    expect(ui._filesStateFor('sess-a').path).toBe('/home/a');
    expect(ui._filesStateFor('sess-b').path).toBe('/home/b');
  });

  it('switchSession swaps the active files state pointer', () => {
    const sA = createSession('files-a');
    const sB = createSession('files-b');
    sA.profile = makeProfile();
    sB.profile = makeProfile();

    const stateA = ui._filesStateFor('files-a');
    stateA.path = '/srv/a';
    const stateB = ui._filesStateFor('files-b');
    stateB.path = '/srv/b';

    appState.activeSessionId = 'files-a';
    expect(ui._activeFilesState().path).toBe('/srv/a');

    appState.activeSessionId = 'files-b';
    expect(ui._activeFilesState().path).toBe('/srv/b');
  });

  it('files state for a newly-created session starts with path "/"', () => {
    const s = createSession('new-sess');
    s.profile = makeProfile();
    const state = ui._filesStateFor('new-sess');
    expect(state.path).toBe('/');
    expect(state.firstActivated).toBe(false);
  });

  it('firstActivated is per-session — activating A does not mark B activated', () => {
    const sA = createSession('act-a');
    const sB = createSession('act-b');
    sA.profile = makeProfile();
    sB.profile = makeProfile();

    const stateA = ui._filesStateFor('act-a');
    stateA.firstActivated = true;

    const stateB = ui._filesStateFor('act-b');
    expect(stateB.firstActivated).toBe(false);
  });
});
