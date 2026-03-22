/**
 * Unit tests for per-session terminal creation (#261)
 */
import { describe, it, expect, beforeEach, vi } from 'vitest';

// Stub browser globals before importing modules

const terminalInstances: { open: ReturnType<typeof vi.fn>; loadAddon: ReturnType<typeof vi.fn>; onBell: ReturnType<typeof vi.fn>; writeln: ReturnType<typeof vi.fn>; parser: { registerOscHandler: ReturnType<typeof vi.fn> }; options: Record<string, unknown>; buffer: { active: { cursorY: number; getLine: ReturnType<typeof vi.fn> } } }[] = [];
const fitAddonInstances: { fit: ReturnType<typeof vi.fn> }[] = [];

// Use function constructor pattern (not arrow fn) so `new Terminal(...)` works
vi.stubGlobal('Terminal', function TerminalMock() {
  const inst = {
    open: vi.fn(),
    loadAddon: vi.fn(),
    onBell: vi.fn(),
    writeln: vi.fn(),
    parser: { registerOscHandler: vi.fn() },
    options: {} as Record<string, unknown>,
    buffer: { active: { cursorY: 0, getLine: vi.fn() } },
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

// Track createElement calls and appended children
const createdDivs: Array<{ tagName: string; dataset: Record<string, string>; style: Record<string, string>; className: string; children: unknown[]; appendChild: ReturnType<typeof vi.fn> }> = [];
const terminalContainerChildren: unknown[] = [];
const terminalContainer = {
  tagName: 'DIV',
  id: 'terminal',
  dataset: {} as Record<string, string>,
  appendChild: vi.fn((child: unknown) => {
    terminalContainerChildren.push(child);
    return child;
  }),
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
      children: [] as unknown[],
      appendChild: vi.fn(function (this: { children: unknown[] }, child: unknown) {
        this.children.push(child);
        return child;
      }),
      classList: {
        add: vi.fn(),
        toggle: vi.fn(),
        contains: vi.fn(() => false),
      },
      setAttribute: vi.fn(),
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
vi.stubGlobal('WebSocket', { OPEN: 1 });
vi.stubGlobal('performance', { now: vi.fn(() => 0) });
vi.stubGlobal('location', { hostname: 'localhost' });

const { createSessionTerminal } = await import('../terminal.js');

describe('createSessionTerminal (#261)', () => {
  beforeEach(() => {
    createdDivs.length = 0;
    terminalInstances.length = 0;
    fitAddonInstances.length = 0;
    terminalContainerChildren.length = 0;
    storage.clear();
    vi.clearAllMocks();
  });

  it('returns an object with terminal and fitAddon', () => {
    const result = createSessionTerminal('test-session-1');
    expect(result).toHaveProperty('terminal');
    expect(result).toHaveProperty('fitAddon');
    expect(result.terminal).toBeDefined();
    expect(result.fitAddon).toBeDefined();
  });

  it('creates a DOM container with data-session-id', () => {
    const sessionId = 'myhost:22:user:1234';
    createSessionTerminal(sessionId);

    // Should have created a div element
    expect(document.createElement).toHaveBeenCalledWith('div');

    // Find the created div with the correct session ID
    const sessionDiv = createdDivs.find(
      (el) => el.dataset['sessionId'] === sessionId
    );
    expect(sessionDiv).toBeDefined();
  });

  it('appends session container to #terminal', () => {
    createSessionTerminal('sess-1');
    expect(terminalContainer.appendChild).toHaveBeenCalled();
    // The first child appended should be the session div
    expect(terminalContainerChildren.length).toBeGreaterThan(0);
    const child = terminalContainerChildren[0] as { dataset: Record<string, string> };
    expect(child.dataset['sessionId']).toBe('sess-1');
  });

  it('opens terminal in the session container, not #terminal directly', () => {
    createSessionTerminal('sess-2');
    // The Terminal.open should be called with the session div
    expect(terminalInstances.length).toBeGreaterThan(0);
    const openArg = terminalInstances[0]!.open.mock.calls[0]?.[0] as { dataset: Record<string, string> };
    expect(openArg.dataset['sessionId']).toBe('sess-2');
  });

  it('wires bell handler on the new terminal', () => {
    createSessionTerminal('sess-3');
    expect(terminalInstances[0]!.onBell).toHaveBeenCalled();
  });

  it('wires OSC 9 and OSC 777 handlers', () => {
    createSessionTerminal('sess-4');
    const calls = terminalInstances[0]!.parser.registerOscHandler.mock.calls;
    expect(calls.length).toBe(2);
    expect(calls[0]![0]).toBe(9);
    expect(calls[1]![0]).toBe(777);
  });

  it('creates a new Terminal and FitAddon instance per call', () => {
    createSessionTerminal('sess-a');
    createSessionTerminal('sess-b');
    expect(terminalInstances.length).toBe(2);
    expect(fitAddonInstances.length).toBe(2);
  });
});
