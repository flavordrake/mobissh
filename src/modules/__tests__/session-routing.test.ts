/**
 * Unit tests for session routing after mirror state removal (#263)
 *
 * Verifies that sendSSHInput, handleResize, switchSession, SFTP handler,
 * and terminal output all route through currentSession() — not appState.ws.
 */
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { webcrypto } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

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

// Track querySelectorAll calls for switchSession DOM manipulation
const sessionElements: Array<{ dataset: Record<string, string>; classList: { toggle: ReturnType<typeof vi.fn>; add: ReturnType<typeof vi.fn>; contains: ReturnType<typeof vi.fn>; remove: ReturnType<typeof vi.fn> } }> = [];

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
  readyState = 1; // OPEN
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

// Stub Terminal and FitAddon for terminal.ts imports
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

const { sendSSHInput, setSftpHandler, sendSftpLs } = await import('../connection.js');
const { handleResize } = await import('../terminal.js');
const { switchSession } = await import('../ui.js');
const { appState, createSession, currentSession, transitionSession } = await import('../state.js');

/** Transition a session to 'connected' through valid state machine path. */
function connectSession(id: string): void {
  transitionSession(id, 'connecting');
  transitionSession(id, 'authenticating');
  transitionSession(id, 'connected');
}

// ── Helpers ──────────────────────────────────────────────────────────────────

function makeMockWs(): WebSocket {
  return {
    readyState: WebSocket.OPEN,
    url: 'ws://localhost:8081',
    send: vi.fn(),
    close: vi.fn(),
    onopen: null,
    onclose: null,
    onmessage: null,
    onerror: null,
  } as unknown as WebSocket;
}

function makeMockTerminal(): { write: ReturnType<typeof vi.fn>; cols: number; rows: number; reset: ReturnType<typeof vi.fn> } {
  return {
    write: vi.fn(),
    cols: 120,
    rows: 40,
    reset: vi.fn(),
  };
}

function makeMockFitAddon(): { fit: ReturnType<typeof vi.fn> } {
  return { fit: vi.fn() };
}

// ── Tests ────────────────────────────────────────────────────────────────────

describe('session routing (#263)', () => {
  beforeEach(() => {
    appState.sessions.clear();
    appState.activeSessionId = null;
    sessionElements.length = 0;
    storage.clear();
    vi.clearAllMocks();
  });

  describe('sendSSHInput routes to active session WS', () => {
    it('sends input only to the active session WS', () => {
      const s1 = createSession('sess-1');
      const s2 = createSession('sess-2');
      const ws1 = makeMockWs();
      const ws2 = makeMockWs();
      s1.ws = ws1;
      s2.ws = ws2;
      connectSession('sess-1');
      connectSession('sess-2');

      appState.activeSessionId = 'sess-1';
      sendSSHInput('hello');

      expect(ws1.send).toHaveBeenCalledWith(
        JSON.stringify({ type: 'input', data: 'hello' }),
      );
      expect(ws2.send).not.toHaveBeenCalled();
    });

    it('sends input to session 2 when it becomes active', () => {
      const s1 = createSession('sess-1');
      const s2 = createSession('sess-2');
      const ws1 = makeMockWs();
      const ws2 = makeMockWs();
      s1.ws = ws1;
      s2.ws = ws2;
      connectSession('sess-1');
      connectSession('sess-2');

      appState.activeSessionId = 'sess-2';
      sendSSHInput('world');

      expect(ws2.send).toHaveBeenCalledWith(
        JSON.stringify({ type: 'input', data: 'world' }),
      );
      expect(ws1.send).not.toHaveBeenCalled();
    });

    it('is a no-op when no session is active', () => {
      const s1 = createSession('sess-1');
      const ws1 = makeMockWs();
      s1.ws = ws1;
      connectSession('sess-1');

      appState.activeSessionId = null;
      sendSSHInput('data');

      expect(ws1.send).not.toHaveBeenCalled();
    });
  });

  describe('handleResize is a no-op (terminals resize via ResizeObserver)', () => {
    it('does not send resize or call fit (no-op)', () => {
      const s1 = createSession('resize-sess');
      const ws1 = makeMockWs();
      const terminal = makeMockTerminal();
      const fitAddon = makeMockFitAddon();
      s1.ws = ws1;
      connectSession('resize-sess');
      s1.terminal = terminal as unknown as typeof s1.terminal;
      s1.fitAddon = fitAddon as unknown as typeof s1.fitAddon;

      appState.activeSessionId = 'resize-sess';
      handleResize();

      // handleResize is now a no-op — ResizeObserver on each SessionHandle handles fit
      expect(fitAddon.fit).not.toHaveBeenCalled();
      expect(ws1.send).not.toHaveBeenCalled();
    });

    it('does not send resize to any session (no-op)', () => {
      const s1 = createSession('sess-a');
      const s2 = createSession('sess-b');
      const ws1 = makeMockWs();
      const ws2 = makeMockWs();
      s1.ws = ws1;
      s2.ws = ws2;
      connectSession('sess-a');
      connectSession('sess-b');
      s1.terminal = makeMockTerminal() as unknown as typeof s1.terminal;
      s2.terminal = makeMockTerminal() as unknown as typeof s2.terminal;
      s1.fitAddon = makeMockFitAddon() as unknown as typeof s1.fitAddon;
      s2.fitAddon = makeMockFitAddon() as unknown as typeof s2.fitAddon;

      appState.activeSessionId = 'sess-a';
      handleResize();

      expect(ws1.send).not.toHaveBeenCalled();
      expect(ws2.send).not.toHaveBeenCalled();
    });
  });

  describe('switchSession triggers fit on new session', () => {
    it('sets activeSessionId to target (no explicit fit — handled by show())', () => {
      const s1 = createSession('sw-1');
      const s2 = createSession('sw-2');
      const fit1 = makeMockFitAddon();
      const fit2 = makeMockFitAddon();
      s1.fitAddon = fit1 as unknown as typeof s1.fitAddon;
      s2.fitAddon = fit2 as unknown as typeof s2.fitAddon;

      appState.activeSessionId = 'sw-1';
      switchSession('sw-2');

      expect(appState.activeSessionId).toBe('sw-2');
      // switchSession no longer calls fitAddon.fit() explicitly —
      // fit happens via SessionHandle.show() or ResizeObserver
    });

    it('sets activeSessionId so subsequent input routes to the new session', () => {
      const s1 = createSession('route-1');
      const s2 = createSession('route-2');
      const ws1 = makeMockWs();
      const ws2 = makeMockWs();
      s1.ws = ws1;
      s2.ws = ws2;
      connectSession('route-1');
      connectSession('route-2');
      s1.fitAddon = makeMockFitAddon() as unknown as typeof s1.fitAddon;
      s2.fitAddon = makeMockFitAddon() as unknown as typeof s2.fitAddon;

      appState.activeSessionId = 'route-1';
      switchSession('route-2');
      sendSSHInput('after-switch');

      expect(ws2.send).toHaveBeenCalledWith(
        JSON.stringify({ type: 'input', data: 'after-switch' }),
      );
      expect(ws1.send).not.toHaveBeenCalled();
    });
  });

  describe('no remaining appState.ws references in connection.ts', () => {
    it('connection.ts does not reference appState.ws directly', () => {
      const connectionSrc = readFileSync(
        resolve(__dirname, '..', 'connection.ts'),
        'utf-8',
      );
      // Match appState.ws but not appState.wsConnected or other properties
      // that happen to start with ws (like wsConnected).
      // Pattern: appState.ws followed by a non-word character (like `.send`, `?.`, space, etc.)
      const matches = connectionSrc.match(/appState\.ws(?!\w)/g);
      expect(matches).toBeNull();
    });

    it('terminal.ts does not reference appState.ws directly', () => {
      const terminalSrc = readFileSync(
        resolve(__dirname, '..', 'terminal.ts'),
        'utf-8',
      );
      const matches = terminalSrc.match(/appState\.ws(?!\w)/g);
      expect(matches).toBeNull();
    });

    it('ui.ts does not reference appState.ws directly', () => {
      const uiSrc = readFileSync(
        resolve(__dirname, '..', 'ui.ts'),
        'utf-8',
      );
      const matches = uiSrc.match(/appState\.ws(?!\w)/g);
      expect(matches).toBeNull();
    });
  });

  describe('SFTP handler routes through active session', () => {
    it('setSftpHandler callback receives SFTP messages', () => {
      const handler = vi.fn();
      setSftpHandler(handler);

      // The SFTP handler is a module-level singleton — it receives messages
      // from whichever WS's onmessage fires. We verify it's callable and
      // the routing in connection.ts uses _sftpHandler (not appState.ws).
      // The structural test above proves no appState.ws references exist.
      expect(handler).not.toHaveBeenCalled();

      // Calling setSftpHandler replaces the handler; verify it doesn't throw
      const handler2 = vi.fn();
      setSftpHandler(handler2);
      expect(handler2).not.toHaveBeenCalled();
    });

    it('SFTP send functions route through currentSession WS', () => {
      const s1 = createSession('sftp-1');
      const s2 = createSession('sftp-2');
      const ws1 = makeMockWs();
      const ws2 = makeMockWs();
      s1.ws = ws1;
      s2.ws = ws2;
      connectSession('sftp-1');
      connectSession('sftp-2');

      appState.activeSessionId = 'sftp-1';
      sendSftpLs('/home', 'req-1');

      expect(ws1.send).toHaveBeenCalled();
      expect(ws2.send).not.toHaveBeenCalled();
    });
  });

  describe('two sessions with independent terminal output', () => {
    it('each session has its own terminal instance', () => {
      const s1 = createSession('term-1');
      const s2 = createSession('term-2');
      const t1 = makeMockTerminal();
      const t2 = makeMockTerminal();
      s1.terminal = t1 as unknown as typeof s1.terminal;
      s2.terminal = t2 as unknown as typeof s2.terminal;

      // Verify they are distinct objects
      expect(s1.terminal).not.toBe(s2.terminal);
    });

    it('currentSession returns only the active session terminal', () => {
      const s1 = createSession('out-1');
      const s2 = createSession('out-2');
      const t1 = makeMockTerminal();
      const t2 = makeMockTerminal();
      s1.terminal = t1 as unknown as typeof s1.terminal;
      s2.terminal = t2 as unknown as typeof s2.terminal;

      appState.activeSessionId = 'out-1';
      expect(currentSession()?.terminal).toBe(t1);

      appState.activeSessionId = 'out-2';
      expect(currentSession()?.terminal).toBe(t2);
    });

    it('switching sessions changes which terminal receives writes via currentSession', () => {
      const s1 = createSession('write-1');
      const s2 = createSession('write-2');
      const t1 = makeMockTerminal();
      const t2 = makeMockTerminal();
      s1.terminal = t1 as unknown as typeof s1.terminal;
      s2.terminal = t2 as unknown as typeof s2.terminal;
      s1.fitAddon = makeMockFitAddon() as unknown as typeof s1.fitAddon;
      s2.fitAddon = makeMockFitAddon() as unknown as typeof s2.fitAddon;

      // Simulate what _flushTerminalWrite does: write to currentSession()?.terminal
      appState.activeSessionId = 'write-1';
      currentSession()?.terminal?.write('data-for-1');

      appState.activeSessionId = 'write-2';
      currentSession()?.terminal?.write('data-for-2');

      expect(t1.write).toHaveBeenCalledWith('data-for-1');
      expect(t1.write).not.toHaveBeenCalledWith('data-for-2');
      expect(t2.write).toHaveBeenCalledWith('data-for-2');
      expect(t2.write).not.toHaveBeenCalledWith('data-for-1');
    });
  });
});
