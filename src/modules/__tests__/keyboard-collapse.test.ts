import { describe, it, expect, beforeEach, vi, afterEach } from 'vitest';

/**
 * Test: keyboard dismiss with IME hover-bottom should clear #app inline height.
 *
 * Regression test for #397: when the on-screen keyboard dismisses, intermediate
 * visualViewport.resize events fire with heights that still trigger keyboardVisible.
 * The rAF-coalesced handler must use the FINAL viewport height and clear inline
 * style when keyboard is fully dismissed.
 */

// ── Stubs ──────────────────────────────────────────────────────────────────

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

const appEl = {
  style: { height: '' },
};

const setPropertyMock = vi.fn();

vi.stubGlobal('document', {
  getElementById: (id: string) => (id === 'app' ? appEl : null),
  querySelector: () => null,
  addEventListener: vi.fn(),
  visibilityState: 'visible',
  documentElement: {
    style: { setProperty: setPropertyMock },
    dataset: {},
  },
  createElement: vi.fn(() => ({
    className: '', textContent: '', innerHTML: '',
    appendChild: vi.fn(), addEventListener: vi.fn(), querySelector: vi.fn(),
  })),
  fonts: { ready: Promise.resolve() },
  body: { appendChild: vi.fn() },
});

vi.stubGlobal('getComputedStyle', () => ({
  getPropertyValue: () => '',
}));

vi.stubGlobal('Notification', { permission: 'granted' });

// Track rAF callbacks
let rafCallbacks: Array<() => void> = [];
vi.stubGlobal('requestAnimationFrame', (cb: () => void) => {
  rafCallbacks.push(cb);
  return rafCallbacks.length;
});

// Viewport mock with event listeners
let viewportListeners: Record<string, Array<() => void>> = {};
const viewportMock = {
  height: 900,
  width: 400,
  offsetTop: 0,
  scale: 1,
  addEventListener: (event: string, cb: () => void) => {
    if (!viewportListeners[event]) viewportListeners[event] = [];
    viewportListeners[event]!.push(cb);
  },
};

vi.stubGlobal('window', {
  addEventListener: vi.fn(),
  visualViewport: viewportMock,
  outerHeight: 900,
  innerHeight: 900,
});

vi.useFakeTimers();

// Import AFTER stubs
const { initKeyboardAwareness, getKeyboardVisible } = await import('../terminal.js');

// Helper: fire viewport resize
function fireViewportResize(height: number): void {
  viewportMock.height = height;
  for (const cb of viewportListeners['resize'] ?? []) {
    cb();
  }
}

// Helper: flush all pending rAF callbacks
function flushRAF(): void {
  const cbs = rafCallbacks.slice();
  rafCallbacks = [];
  for (const cb of cbs) cb();
}

describe('keyboard collapse — #app height cleared on dismiss (#397)', () => {
  beforeEach(() => {
    appEl.style.height = '';
    setPropertyMock.mockClear();
    viewportListeners = {};
    rafCallbacks = [];
    viewportMock.height = 900;
    viewportMock.scale = 1;

    // Register listeners
    initKeyboardAwareness();
  });

  it('sets pixel height when keyboard is open', () => {
    // Simulate keyboard opening: viewport shrinks to 500px (< 900 * 0.75 = 675)
    fireViewportResize(500);
    flushRAF();

    expect(appEl.style.height).toBe('500px');
    expect(getKeyboardVisible()).toBe(true);
  });

  it('clears pixel height when keyboard fully dismisses', () => {
    // Keyboard open
    fireViewportResize(500);
    flushRAF();
    expect(appEl.style.height).toBe('500px');

    // Keyboard dismiss: viewport returns to full height
    fireViewportResize(900);
    flushRAF();

    expect(appEl.style.height).toBe('');
    expect(getKeyboardVisible()).toBe(false);
  });

  it('clears height after intermediate resize events during dismiss animation', () => {
    // Keyboard open
    fireViewportResize(500);
    flushRAF();
    expect(appEl.style.height).toBe('500px');

    // Dismiss animation: multiple intermediate events in same frame
    // These fire rapidly — only the last should take effect
    fireViewportResize(600);
    fireViewportResize(700);
    fireViewportResize(900); // final: full height
    flushRAF();

    // After rAF flushes, #app should have no inline height
    expect(appEl.style.height).toBe('');
    expect(getKeyboardVisible()).toBe(false);
  });

  it('uses last viewport height when multiple events fire before rAF', () => {
    // Keyboard open
    fireViewportResize(500);
    flushRAF();

    // Multiple rapid resize events, last one still shows keyboard open
    fireViewportResize(550);
    fireViewportResize(600);
    // Don't go to full height — keyboard still partially visible
    flushRAF();

    // Should use the last value (600), which is still < 675, so keyboard still visible
    expect(appEl.style.height).toBe('600px');
    expect(getKeyboardVisible()).toBe(true);
  });

  it('clears --viewport-height custom property when keyboard dismisses', () => {
    // Keyboard open
    fireViewportResize(500);
    flushRAF();

    setPropertyMock.mockClear();

    // Keyboard dismiss
    fireViewportResize(900);
    flushRAF();

    // When keyboard is fully dismissed, --viewport-height should be cleared
    // so CSS 100dvh takes over
    expect(setPropertyMock).toHaveBeenCalledWith('--viewport-height', '');
  });
});
