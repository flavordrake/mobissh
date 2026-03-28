/**
 * Unit tests for SessionHandle class (#374)
 *
 * TDD red baseline: session.ts doesn't exist yet, so the import fails.
 * These tests define the expected API for the SessionHandle refactor.
 */
import { describe, it, expect, beforeEach, vi } from 'vitest';

// Stub browser globals before importing modules

const terminalInstances: {
  open: ReturnType<typeof vi.fn>;
  loadAddon: ReturnType<typeof vi.fn>;
  onBell: ReturnType<typeof vi.fn>;
  dispose: ReturnType<typeof vi.fn>;
  refresh: ReturnType<typeof vi.fn>;
  cols: number;
  rows: number;
  parser: { registerOscHandler: ReturnType<typeof vi.fn> };
  options: Record<string, unknown>;
}[] = [];

const fitAddonInstances: { fit: ReturnType<typeof vi.fn> }[] = [];

vi.stubGlobal('Terminal', function TerminalMock() {
  const inst = {
    open: vi.fn(),
    loadAddon: vi.fn(),
    onBell: vi.fn(),
    dispose: vi.fn(),
    refresh: vi.fn(),
    cols: 80,
    rows: 24,
    parser: { registerOscHandler: vi.fn() },
    options: {} as Record<string, unknown>,
  };
  terminalInstances.push(inst);
  return inst;
});

vi.stubGlobal('FitAddon', { FitAddon: function FitAddonMock() {
  const inst = { fit: vi.fn() };
  fitAddonInstances.push(inst);
  return inst;
} });

vi.stubGlobal('ClipboardAddon', { ClipboardAddon: vi.fn() });

// Track DOM elements
const createdDivs: Array<{
  tagName: string;
  dataset: Record<string, string>;
  style: Record<string, string>;
  className: string;
  classList: {
    add: ReturnType<typeof vi.fn>;
    remove: ReturnType<typeof vi.fn>;
    contains: ReturnType<typeof vi.fn>;
    toggle: ReturnType<typeof vi.fn>;
  };
  children: unknown[];
  appendChild: ReturnType<typeof vi.fn>;
  remove: ReturnType<typeof vi.fn>;
  offsetHeight: number;
}> = [];

const terminalContainer = {
  tagName: 'DIV',
  id: 'terminal',
  dataset: {} as Record<string, string>,
  appendChild: vi.fn((child: unknown) => child),
  querySelector: vi.fn(() => null),
};

const elementsById: Record<string, unknown> = {
  terminal: terminalContainer,
};

vi.stubGlobal('document', {
  getElementById: vi.fn((id: string) => elementsById[id] ?? null),
  createElement: vi.fn((tag: string) => {
    const el = {
      tagName: tag.toUpperCase(),
      dataset: {} as Record<string, string>,
      style: { display: '', width: '', height: '' } as Record<string, string>,
      className: '',
      classList: {
        add: vi.fn(function (this: { _classes: Set<string> }, cls: string) { this._classes.add(cls); }),
        remove: vi.fn(function (this: { _classes: Set<string> }, cls: string) { this._classes.delete(cls); }),
        contains: vi.fn(function (this: { _classes: Set<string> }, cls: string) { return this._classes.has(cls); }),
        toggle: vi.fn(),
        _classes: new Set<string>(),
      },
      children: [] as unknown[],
      appendChild: vi.fn(function (this: { children: unknown[] }, child: unknown) {
        this.children.push(child);
        return child;
      }),
      remove: vi.fn(),
      offsetHeight: 500,
    };
    createdDivs.push(el);
    return el;
  }),
  documentElement: {
    style: { setProperty: vi.fn() },
    dataset: {},
  },
  hasFocus: vi.fn(() => true),
  visibilityState: 'visible',
  fonts: { ready: Promise.resolve() },
  querySelector: vi.fn(() => null),
  querySelectorAll: vi.fn(() => []),
  addEventListener: vi.fn(),
});

const storage = new Map<string, string>();
vi.stubGlobal('localStorage', {
  getItem: (key: string) => storage.get(key) ?? null,
  setItem: (key: string, value: string) => { storage.set(key, value); },
  removeItem: (key: string) => { storage.delete(key); },
  clear: () => { storage.clear(); },
});

vi.stubGlobal('window', {
  addEventListener: vi.fn(),
  visualViewport: null,
  outerHeight: 800,
});

vi.stubGlobal('Notification', { permission: 'default' });
vi.stubGlobal('navigator', { serviceWorker: undefined });
vi.stubGlobal('getComputedStyle', vi.fn(() => ({
  getPropertyValue: vi.fn(() => '48px'),
})));
vi.stubGlobal('CSS', { escape: (s: string) => s });

let wsSendSpy: ReturnType<typeof vi.fn>;
let wsCloseSpy: ReturnType<typeof vi.fn>;
let wsInstances: Array<{ readyState: number; send: ReturnType<typeof vi.fn>; close: ReturnType<typeof vi.fn>; onopen: (() => void) | null; onclose: (() => void) | null; onerror: (() => void) | null; onmessage: ((e: { data: string }) => void) | null }>;

function resetWsMock(): void {
  wsInstances = [];
  wsSendSpy = vi.fn();
  wsCloseSpy = vi.fn();
}

vi.stubGlobal('WebSocket', Object.assign(
  function MockWebSocket() {
    const ws = {
      readyState: 1, // OPEN
      send: wsSendSpy,
      close: wsCloseSpy,
      onopen: null as (() => void) | null,
      onclose: null as (() => void) | null,
      onerror: null as (() => void) | null,
      onmessage: null as ((e: { data: string }) => void) | null,
    };
    wsInstances.push(ws);
    return ws;
  },
  { OPEN: 1, CLOSED: 3 },
));

vi.stubGlobal('performance', { now: vi.fn(() => 0) });
vi.stubGlobal('location', { hostname: 'localhost' });

// Import the module under test. This will FAIL until session.ts is created.
const { SessionHandle } = await import('../session.js');

describe('SessionHandle (#374)', () => {
  beforeEach(() => {
    createdDivs.length = 0;
    terminalInstances.length = 0;
    fitAddonInstances.length = 0;
    storage.clear();
    resetWsMock();
    vi.clearAllMocks();
  });

  // -- Construction --

  describe('construction', () => {
    it('creates a terminal and fitAddon', () => {
      const handle = new SessionHandle('sess-1', { name: 'test', host: 'localhost', port: 22, username: 'user', authType: 'password' as const });
      expect(handle.terminal).toBeDefined();
      expect(handle.fitAddon).toBeDefined();
      expect(terminalInstances.length).toBe(1);
      expect(fitAddonInstances.length).toBe(1);
    });

    it('starts in idle state', () => {
      const handle = new SessionHandle('sess-2', { name: 'test', host: 'localhost', port: 22, username: 'user', authType: 'password' as const });
      expect(handle.state).toBe('idle');
    });

    it('creates a container with data-session-id attribute', () => {
      const sessionId = 'myhost:22:user:abc';
      new SessionHandle(sessionId, { name: 'test', host: 'myhost', port: 22, username: 'user', authType: 'password' as const });

      const containerDiv = createdDivs.find(
        (el) => el.dataset['sessionId'] === sessionId,
      );
      expect(containerDiv).toBeDefined();
    });
  });

  // -- show/hide --

  describe('show/hide', () => {
    it('show() removes hidden class from container', () => {
      const handle = new SessionHandle('sess-show', { name: 'test', host: 'localhost', port: 22, username: 'user', authType: 'password' as const });
      handle.show();
      const container = createdDivs.find(el => el.dataset['sessionId'] === 'sess-show');
      expect(container!.classList.remove).toHaveBeenCalledWith('hidden');
    });

    it('hide() adds hidden class to container', () => {
      const handle = new SessionHandle('sess-hide', { name: 'test', host: 'localhost', port: 22, username: 'user', authType: 'password' as const });
      handle.hide();
      const container = createdDivs.find(el => el.dataset['sessionId'] === 'sess-hide');
      expect(container!.classList.add).toHaveBeenCalledWith('hidden');
    });

    it('fitIfVisible() calls fitAddon.fit() when container has non-zero height', () => {
      const handle = new SessionHandle('sess-fit', { name: 'test', host: 'localhost', port: 22, username: 'user', authType: 'password' as const });
      // offsetHeight defaults to 500 (non-zero) in our mock
      handle.fitIfVisible();
      expect(fitAddonInstances[0]!.fit).toHaveBeenCalled();
    });

    it('fitIfVisible() does NOT call fitAddon.fit() when container has zero height', () => {
      const handle = new SessionHandle('sess-nofit', { name: 'test', host: 'localhost', port: 22, username: 'user', authType: 'password' as const });
      const container = createdDivs.find(el => el.dataset['sessionId'] === 'sess-nofit');
      // Simulate zero height (hidden/collapsed container)
      container!.offsetHeight = 0;
      handle.fitIfVisible();
      expect(fitAddonInstances[0]!.fit).not.toHaveBeenCalled();
    });

    it('fitIfVisible() calls terminal.refresh() after fit', () => {
      const handle = new SessionHandle('sess-refresh', { name: 'test', host: 'localhost', port: 22, username: 'user', authType: 'password' as const });
      handle.fitIfVisible();
      expect(fitAddonInstances[0]!.fit).toHaveBeenCalled();
      expect(terminalInstances[0]!.refresh).toHaveBeenCalled();
    });
  });

  // -- Connection lifecycle --

  describe('connection lifecycle', () => {
    it('connect() creates a WebSocket and transitions to connecting', () => {
      const handle = new SessionHandle('sess-conn', { name: 'test', host: 'testhost', port: 22, username: 'user', authType: 'password' as const });
      handle.connect();
      expect(wsInstances.length).toBe(1);
      expect(handle.state).toBe('connecting');
    });

    it('reconnect() is idempotent - returns existing promise if already reconnecting', async () => {
      const handle = new SessionHandle('sess-recon', { name: 'test', host: 'testhost', port: 22, username: 'user', authType: 'password' as const });
      // Get into a state where reconnect is valid
      handle.connect();
      // Simulate transition to connected then disconnected
      handle._setState('connected');
      handle._setState('disconnected');

      const p1 = handle.reconnect();
      const p2 = handle.reconnect();
      expect(p1).toBe(p2);
    });

    it('disconnect() closes WebSocket and transitions to disconnected', () => {
      const handle = new SessionHandle('sess-disc', { name: 'test', host: 'testhost', port: 22, username: 'user', authType: 'password' as const });
      handle.connect();
      handle._setState('connected');
      handle.disconnect();
      expect(wsCloseSpy).toHaveBeenCalled();
      expect(handle.state).toBe('disconnected');
    });

    it('sendInput() sends to WebSocket when connected', () => {
      const handle = new SessionHandle('sess-input', { name: 'test', host: 'testhost', port: 22, username: 'user', authType: 'password' as const });
      handle.connect();
      handle._setState('connected');
      handle.sendInput('ls\n');
      expect(wsSendSpy).toHaveBeenCalledWith(
        expect.stringContaining('ls'),
      );
    });

    it('sendInput() drops input with toast when disconnected', () => {
      const handle = new SessionHandle('sess-drop', { name: 'test', host: 'testhost', port: 22, username: 'user', authType: 'password' as const });
      // Session in idle state (not connected)
      handle.sendInput('ls\n');
      // Should NOT have sent anything via WebSocket
      expect(wsSendSpy).not.toHaveBeenCalled();
    });
  });

  // -- Cleanup --

  describe('cleanup', () => {
    it('close() disposes terminal', () => {
      const handle = new SessionHandle('sess-close', { name: 'test', host: 'localhost', port: 22, username: 'user', authType: 'password' as const });
      handle.close();
      expect(terminalInstances[0]!.dispose).toHaveBeenCalled();
    });

    it('close() removes container from DOM', () => {
      const handle = new SessionHandle('sess-remove', { name: 'test', host: 'localhost', port: 22, username: 'user', authType: 'password' as const });
      const container = createdDivs.find(el => el.dataset['sessionId'] === 'sess-remove');
      handle.close();
      expect(container!.remove).toHaveBeenCalled();
    });
  });

  // -- State isolation --

  describe('state isolation', () => {
    it('two SessionHandle instances do not share state', () => {
      const h1 = new SessionHandle('sess-iso-1', { name: 'test1', host: 'host1', port: 22, username: 'user1', authType: 'password' as const });
      const h2 = new SessionHandle('sess-iso-2', { name: 'test2', host: 'host2', port: 22, username: 'user2', authType: 'password' as const });

      expect(h1.terminal).not.toBe(h2.terminal);
      expect(h1.fitAddon).not.toBe(h2.fitAddon);
      expect(h1.state).toBe('idle');
      expect(h2.state).toBe('idle');

      h1.connect();
      expect(h1.state).toBe('connecting');
      expect(h2.state).toBe('idle');
    });

    it('disconnecting one does not affect the other', () => {
      const h1 = new SessionHandle('sess-pair-1', { name: 'test1', host: 'host1', port: 22, username: 'user1', authType: 'password' as const });
      const h2 = new SessionHandle('sess-pair-2', { name: 'test2', host: 'host2', port: 22, username: 'user2', authType: 'password' as const });

      h1.connect();
      h2.connect();
      h1._setState('connected');
      h2._setState('connected');

      h1.disconnect();
      expect(h1.state).toBe('disconnected');
      expect(h2.state).toBe('connected');
    });
  });
});
