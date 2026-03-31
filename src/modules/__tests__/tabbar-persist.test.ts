/**
 * TDD tests for tab bar visibility persistence (#393)
 *
 * Verifies that:
 * 1. Toggling tab bar hidden writes tabBarVisible: false to localStorage
 * 2. On cold start (initTabBar), tabBarVisible: false in localStorage starts hidden
 * 3. Toggling tab bar visible writes tabBarVisible: true to localStorage
 *
 * Tests FAIL before the feature is implemented — that is expected for TDD.
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

vi.stubGlobal('document', {
  getElementById: vi.fn(() => ({
    classList: { toggle: vi.fn(), remove: vi.fn(), add: vi.fn(), contains: vi.fn(() => false) },
    addEventListener: vi.fn(),
    dataset: {},
  })),
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
    classList: { toggle: vi.fn() },
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

// Import modules under test AFTER stubs
const { _applyTabBarVisibility, initTabBar } = await import('../ui.js');
const { appState } = await import('../state.js');

describe('tab bar visibility persistence (#393)', () => {
  beforeEach(() => {
    storage.clear();
    appState.tabBarVisible = true;
    vi.clearAllMocks();
  });

  it('toggling tab bar hidden writes tabBarVisible=false to localStorage', () => {
    // Start visible
    appState.tabBarVisible = true;

    // Simulate what toggleTabBar does: flip the state then apply
    appState.tabBarVisible = !appState.tabBarVisible;
    _applyTabBarVisibility();

    // The apply function should persist to localStorage
    expect(storage.get('tabBarVisible')).toBe('false');
  });

  it('cold start reads tabBarVisible=false from localStorage and starts hidden', () => {
    // Pre-seed localStorage with hidden state
    storage.set('tabBarVisible', 'false');

    // initTabBar should read from localStorage and set appState
    initTabBar();

    expect(appState.tabBarVisible).toBe(false);
  });

  it('toggling tab bar visible writes tabBarVisible=true to localStorage', () => {
    // Start hidden
    appState.tabBarVisible = false;

    // Simulate toggle: flip to visible then apply
    appState.tabBarVisible = !appState.tabBarVisible;
    _applyTabBarVisibility();

    // The apply function should persist to localStorage
    expect(storage.get('tabBarVisible')).toBe('true');
  });
});
