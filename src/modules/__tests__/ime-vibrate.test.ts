import { describe, it, expect, beforeEach, vi } from 'vitest';

/**
 * Compose preview tap vibrate (#253) — verify that tapping the IME
 * compose preview textarea triggers haptic feedback via navigator.vibrate.
 *
 * Strategy: mock DOM elements, import and call initIMEInput(), then
 * simulate a tap (touchstart + touchend without significant movement)
 * on the #imeInput textarea while in 'previewing' state.
 */

// ── Stubs ────────────────────────────────────────────────────────────────

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

// Collect addEventListener calls per element so we can dispatch manually
type Listener = { type: string; handler: (e: unknown) => void; options?: AddEventListenerOptions | boolean };
const listenersByEl = new Map<string, Listener[]>();

function makeElement(id: string, tag = 'div'): Record<string, unknown> {
  const listeners: Listener[] = [];
  listenersByEl.set(id, listeners);
  const el: Record<string, unknown> = {
    id,
    tagName: tag.toUpperCase(),
    value: '',
    style: { top: '', bottom: '', maxHeight: '', left: '', right: '' },
    classList: {
      _set: new Set<string>(),
      add(c: string) { (this as { _set: Set<string> })._set.add(c); },
      remove(c: string) { (this as { _set: Set<string> })._set.delete(c); },
      toggle(c: string, force?: boolean) {
        if (force) (this as { _set: Set<string> })._set.add(c);
        else (this as { _set: Set<string> })._set.delete(c);
      },
      contains(c: string) { return (this as { _set: Set<string> })._set.has(c); },
    },
    addEventListener: (type: string, handler: (e: unknown) => void, options?: AddEventListenerOptions | boolean) => {
      listeners.push({ type, handler, options });
    },
    removeEventListener: vi.fn(),
    focus: vi.fn(),
    blur: vi.fn(),
    scrollHeight: 22,
    clientHeight: 22,
    clientWidth: 200,
    offsetHeight: 30,
    getBoundingClientRect: () => ({ top: 0, left: 0, width: 300, height: 30 }),
    setAttribute: vi.fn(),
    getAttribute: () => null,
    querySelector: () => null,
    querySelectorAll: () => [],
    contains: () => false,
    selectionStart: 0,
    selectionEnd: 0,
    setSelectionRange: vi.fn(),
  };
  return el;
}

const elements: Record<string, Record<string, unknown>> = {
  imeInput: makeElement('imeInput', 'textarea'),
  previewModeBtn: makeElement('previewModeBtn'),
  imeActions: makeElement('imeActions'),
  imeClearBtn: makeElement('imeClearBtn'),
  imeCommitBtn: makeElement('imeCommitBtn'),
  imeDockToggle: makeElement('imeDockToggle'),
  terminal: makeElement('terminal'),
  directInput: makeElement('directInput', 'input'),
  previewTimeoutBtn: makeElement('previewTimeoutBtn'),
  previewIdleBtn: makeElement('previewIdleBtn'),
};

vi.stubGlobal('document', {
  getElementById: (id: string) => elements[id] ?? null,
  querySelector: () => null,
  querySelectorAll: () => [],
  addEventListener: vi.fn(),
  visibilityState: 'visible',
  documentElement: {
    style: { setProperty: vi.fn() },
    dataset: {},
  },
  createElement: vi.fn(() => makeElement('_anon')),
  fonts: { ready: Promise.resolve() },
  body: { appendChild: vi.fn() },
  activeElement: null,
});

vi.stubGlobal('getComputedStyle', () => ({
  getPropertyValue: () => '',
  lineHeight: '22',
  paddingTop: '4',
  paddingBottom: '4',
  paddingLeft: '8',
  paddingRight: '8',
  fontSize: '16px',
}));

const vibrateMock = vi.fn();
vi.stubGlobal('navigator', { vibrate: vibrateMock });

vi.stubGlobal('window', {
  addEventListener: vi.fn(),
  removeEventListener: vi.fn(),
  visualViewport: null,
  innerHeight: 800,
  outerHeight: 900,
  innerWidth: 400,
  setTimeout,
  clearTimeout,
  setInterval,
  clearInterval,
  requestAnimationFrame: vi.fn(),
});

vi.stubGlobal('matchMedia', () => ({ matches: false, addEventListener: vi.fn() }));

// ── Import modules under test ────────────────────────────────────────────

vi.mock('../connection.js', () => ({
  sendSSHInput: vi.fn(),
}));
vi.mock('../ui.js', () => ({
  focusIME: vi.fn(),
  setCtrlActive: vi.fn(),
}));
vi.mock('../selection.js', () => ({
  isSelectionActive: vi.fn(() => false),
}));
vi.mock('../state.js', () => ({
  appState: {
    sshConnected: true,
    terminal: null,
    ctrlActive: false,
    imeMode: true,
    isComposing: false,
  },
}));

const ime = await import('../ime.js');

// ── Helpers ──────────────────────────────────────────────────────────────

function dispatchOn(elId: string, type: string, detail?: Record<string, unknown>): void {
  const listeners = listenersByEl.get(elId) ?? [];
  for (const l of listeners) {
    if (l.type === type) {
      l.handler(detail ?? {});
    }
  }
}

// ── Tests ────────────────────────────────────────────────────────────────

describe('compose preview tap vibrate (#253)', () => {
  beforeEach(() => {
    vibrateMock.mockClear();
  });

  it('calls navigator.vibrate(10) on tap when previewing', () => {
    // Wire up all IME event handlers
    ime.initIMEInput();

    const imeEl = elements['imeInput']!;

    // Simulate a composition that ends without preview mode —
    // this puts _imeState into 'previewing' (line 862 in ime.ts)
    // and keeps ime.value non-empty.
    imeEl['value'] = 'hello';
    dispatchOn('imeInput', 'compositionstart', {});
    dispatchOn('imeInput', 'compositionend', { data: 'hello' });

    // At this point, _imeState should be 'previewing' (non-preview-mode path).
    // ime.value may have been cleared by the send path, so re-set it.
    imeEl['value'] = 'hello';

    vibrateMock.mockClear();

    // Simulate a tap: touchstart then touchend (no movement → not claimed)
    dispatchOn('imeInput', 'touchstart', {
      touches: [{ clientY: 100 }],
    });
    dispatchOn('imeInput', 'touchend', {});

    expect(vibrateMock).toHaveBeenCalledWith(10);
  });

  it('does not call vibrate when IME is idle (no compose text)', () => {
    ime.initIMEInput();

    vibrateMock.mockClear();

    // Tap with no active composition — _imeState is idle, should NOT vibrate
    dispatchOn('imeInput', 'touchstart', {
      touches: [{ clientY: 100 }],
    });
    dispatchOn('imeInput', 'touchend', {});

    expect(vibrateMock).not.toHaveBeenCalled();
  });

  it('does not call vibrate on swipe (claimed touch)', () => {
    ime.initIMEInput();
    const imeEl = elements['imeInput']!;
    imeEl['value'] = 'test';

    // Get into previewing state
    dispatchOn('imeInput', 'compositionstart', {});
    dispatchOn('imeInput', 'compositionend', { data: 'test' });
    imeEl['value'] = 'test';

    vibrateMock.mockClear();

    // Simulate a swipe: touchstart, then touchmove with significant Y delta
    dispatchOn('imeInput', 'touchstart', {
      touches: [{ clientY: 100 }],
    });
    dispatchOn('imeInput', 'touchmove', {
      touches: [{ clientY: 70 }],
      preventDefault: vi.fn(),
    });

    vibrateMock.mockClear(); // clear vibrate from swipe history navigation

    // touchend after claimed swipe should NOT trigger tap vibrate
    dispatchOn('imeInput', 'touchend', {});

    expect(vibrateMock).not.toHaveBeenCalled();
  });
});
