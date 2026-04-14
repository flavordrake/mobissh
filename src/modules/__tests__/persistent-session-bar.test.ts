/**
 * TDD tests for issue #452 (retry) — Persistent session bar via CSS overlay.
 *
 * Root constraint: DO NOT MOVE any DOM elements. xterm.js and the
 * ResizeObserver are coupled to the current structure. The prior attempt
 * moved `#key-bar-handle` out of `#panel-terminal` and broke device
 * rendering (reverted at b552f42).
 *
 * The fix is CSS-only:
 *   - `#key-bar-handle` and `#key-bar` stay children of `#panel-terminal`
 *   - When Files is active, `#panel-terminal` stays `.active` too so chrome
 *     keeps rendering
 *   - `body.files-overlay` drives positioning and terminal visibility
 *   - The obsolete "← Terminal" back button is removed from the files panel
 */
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const indexHtml = readFileSync(
  resolve(__dirname, '../../../public/index.html'),
  'utf8',
);

// ── Source/HTML grep tests (no runtime needed) ────────────────────────────

describe('persistent session bar (#452) — DOM structure', () => {
  it('#key-bar-handle is still a child of #panel-terminal (regression guard)', () => {
    // The prior attempt moved this element to a sibling layout, breaking
    // terminal rendering on device. It MUST remain inside panel-terminal.
    const panelStart = indexHtml.indexOf('id="panel-terminal"');
    const panelEnd = indexHtml.indexOf('id="panel-files"');
    const handleStart = indexHtml.indexOf('id="key-bar-handle"');

    expect(panelStart).toBeGreaterThan(-1);
    expect(panelEnd).toBeGreaterThan(panelStart);
    expect(handleStart).toBeGreaterThan(panelStart);
    expect(handleStart).toBeLessThan(panelEnd);
  });

  it('#key-bar is still a child of #panel-terminal (regression guard)', () => {
    const panelStart = indexHtml.indexOf('id="panel-terminal"');
    const panelEnd = indexHtml.indexOf('id="panel-files"');
    const keybarStart = indexHtml.indexOf('id="key-bar"');

    expect(panelStart).toBeGreaterThan(-1);
    expect(panelEnd).toBeGreaterThan(panelStart);
    expect(keybarStart).toBeGreaterThan(panelStart);
    expect(keybarStart).toBeLessThan(panelEnd);
  });

  it('#filesBackToTerminalBtn is removed (hamburger replaces it)', () => {
    // With the persistent session bar, the ≡ menu is always reachable —
    // there is no need for a dedicated back button inside the files panel.
    expect(indexHtml).not.toContain('id="filesBackToTerminalBtn"');
  });
});

// ── Runtime tests for navigateToPanel body-class behavior ─────────────────

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
vi.stubGlobal('history', {
  pushState: vi.fn(),
  replaceState: vi.fn(),
  back: vi.fn(),
});

type ClassListStub = {
  classes: Set<string>;
  add: (c: string) => void;
  remove: (c: string) => void;
  toggle: (c: string, force?: boolean) => void;
  contains: (c: string) => boolean;
};

function makeClassList(): ClassListStub {
  const classes = new Set<string>();
  return {
    classes,
    add: (c: string) => { classes.add(c); },
    remove: (c: string) => { classes.delete(c); },
    toggle: (c: string, force?: boolean) => {
      if (force === true) { classes.add(c); return; }
      if (force === false) { classes.delete(c); return; }
      if (classes.has(c)) classes.delete(c); else classes.add(c);
    },
    contains: (c: string) => classes.has(c),
  };
}

const elements = new Map<string, { id: string; classList: ClassListStub; dataset: Record<string, string> }>();
function ensureElement(id: string): { id: string; classList: ClassListStub; dataset: Record<string, string> } {
  const existing = elements.get(id);
  if (existing) return existing;
  const el = { id, classList: makeClassList(), dataset: {} as Record<string, string> };
  elements.set(id, el);
  return el;
}

const bodyClassList = makeClassList();

vi.stubGlobal('document', {
  getElementById: vi.fn((id: string) => {
    if (['panel-terminal', 'panel-files', 'panel-connect', 'panel-settings'].includes(id)) {
      return ensureElement(id);
    }
    return null;
  }),
  querySelector: vi.fn((_selector: string) => null),
  querySelectorAll: vi.fn((selector: string) => {
    if (selector === '.panel') {
      return ['panel-terminal', 'panel-files', 'panel-connect', 'panel-settings']
        .map((id) => ensureElement(id));
    }
    if (selector === '.tab') return [];
    if (selector === '[data-session-id]') return [];
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
    classList: makeClassList(),
    dataset: {} as Record<string, string>,
  })),
  body: {
    classList: bodyClassList,
    appendChild: vi.fn(),
  },
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
vi.stubGlobal('window', { addEventListener: vi.fn(), visualViewport: null, outerHeight: 800, innerHeight: 800, innerWidth: 400 });
vi.stubGlobal('Notification', { permission: 'default' });
vi.stubGlobal('performance', { now: vi.fn(() => 0) });
vi.stubGlobal('CSS', { escape: (s: string) => s });
vi.stubGlobal('requestAnimationFrame', (cb: () => void) => { cb(); return 1; });
vi.stubGlobal('cancelAnimationFrame', vi.fn());
vi.stubGlobal('getComputedStyle', vi.fn(() => ({ getPropertyValue: vi.fn(() => '48px') })));

vi.stubGlobal('Terminal', function TerminalMock() {
  return {
    open: vi.fn(), loadAddon: vi.fn(), onBell: vi.fn(), writeln: vi.fn(), write: vi.fn(),
    parser: { registerOscHandler: vi.fn() }, options: {} as Record<string, unknown>,
    buffer: { active: { cursorY: 0, getLine: vi.fn() } }, cols: 80, rows: 24,
    reset: vi.fn(), scrollToBottom: vi.fn(),
  };
});
vi.stubGlobal('FitAddon', { FitAddon: function FitAddonMock() { return { fit: vi.fn() }; } });
vi.stubGlobal('ClipboardAddon', { ClipboardAddon: vi.fn() });

const ui = await import('../ui.js');

describe('persistent session bar (#452) — navigateToPanel behavior', () => {
  beforeEach(() => {
    elements.clear();
    bodyClassList.classes.clear();
    storage.clear();
    vi.clearAllMocks();
  });

  it('navigateToPanel("files") adds "files-overlay" class to body', () => {
    ui.navigateToPanel('files');
    expect(bodyClassList.contains('files-overlay')).toBe(true);
  });

  it('navigateToPanel("terminal") removes "files-overlay" class from body', () => {
    ui.navigateToPanel('files');
    expect(bodyClassList.contains('files-overlay')).toBe(true);
    ui.navigateToPanel('terminal');
    expect(bodyClassList.contains('files-overlay')).toBe(false);
  });

  it('navigateToPanel("connect") removes "files-overlay" class from body', () => {
    ui.navigateToPanel('files');
    ui.navigateToPanel('connect');
    expect(bodyClassList.contains('files-overlay')).toBe(false);
  });

  it('#panel-terminal retains .active class after navigateToPanel("files")', () => {
    // Chrome (handle strip + key bar) must keep rendering while files is
    // overlayed — we achieve that by keeping panel-terminal "active".
    ui.navigateToPanel('files');
    const panelTerminal = ensureElement('panel-terminal');
    expect(panelTerminal.classList.contains('active')).toBe(true);
  });

  it('#panel-files becomes .active after navigateToPanel("files")', () => {
    ui.navigateToPanel('files');
    const panelFiles = ensureElement('panel-files');
    expect(panelFiles.classList.contains('active')).toBe(true);
  });

  it('#panel-terminal is not .active after navigateToPanel("connect")', () => {
    // Connect is not a session panel — chrome should not remain.
    ui.navigateToPanel('files');
    ui.navigateToPanel('connect');
    const panelTerminal = ensureElement('panel-terminal');
    expect(panelTerminal.classList.contains('active')).toBe(false);
  });
});
