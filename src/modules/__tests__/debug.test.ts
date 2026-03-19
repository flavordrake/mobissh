import { describe, it, expect, beforeEach, vi } from 'vitest';

// Stub browser globals
const localStore: Record<string, string> = {};
vi.stubGlobal('localStorage', {
  getItem: (k: string) => localStore[k] ?? null,
  setItem: (k: string, v: string) => { localStore[k] = v; },
  removeItem: (k: string) => { delete localStore[k]; },
  clear: () => { for (const k of Object.keys(localStore)) delete localStore[k]; },
  length: 0,
  key: () => null,
});

const clipboardWriteText = vi.fn(() => Promise.resolve());
vi.stubGlobal('navigator', {
  clipboard: { writeText: clipboardWriteText },
});

// Simple DOM element mock
interface MockElement {
  id: string;
  type?: string;
  checked?: boolean;
  classList: { _set: Set<string>; add: (c: string) => void; remove: (c: string) => void; toggle: (c: string, force?: boolean) => void; contains: (c: string) => boolean };
  children: MockElement[];
  textContent: string;
  innerHTML: string;
  scrollTop: number;
  scrollHeight: number;
  style: Record<string, string>;
  _listeners: Record<string, Array<() => void>>;
  addEventListener: (ev: string, fn: () => void) => void;
  dispatchEvent: (ev: { type: string }) => void;
  click: () => void;
  appendChild: (child: MockElement) => void;
  removeChild: (child: MockElement) => void;
  remove: () => void;
}

function mockElement(id: string): MockElement {
  const classSet = new Set<string>();
  const listeners: Record<string, Array<() => void>> = {};
  const children: MockElement[] = [];
  let _innerHTML = '';
  const el: MockElement = {
    id,
    classList: {
      _set: classSet,
      add: (c: string) => classSet.add(c),
      remove: (c: string) => classSet.delete(c),
      toggle: (c: string, force?: boolean) => {
        if (force === undefined) {
          if (classSet.has(c)) classSet.delete(c); else classSet.add(c);
        } else {
          if (force) classSet.add(c); else classSet.delete(c);
        }
      },
      contains: (c: string) => classSet.has(c),
    },
    children,
    textContent: '',
    get innerHTML() { return _innerHTML; },
    set innerHTML(v: string) { _innerHTML = v; if (v === '') children.length = 0; },
    scrollTop: 0,
    scrollHeight: 100,
    style: {},
    _listeners: listeners,
    addEventListener: (ev: string, fn: () => void) => {
      (listeners[ev] ??= []).push(fn);
    },
    dispatchEvent: (ev: { type: string }) => {
      for (const fn of listeners[ev.type] ?? []) fn();
    },
    click: () => {
      for (const fn of listeners['click'] ?? []) fn();
    },
    appendChild: (child: MockElement) => { children.push(child); },
    removeChild: (child: MockElement) => {
      const idx = children.indexOf(child);
      if (idx >= 0) children.splice(idx, 1);
    },
    remove: () => {},
  };
  return el;
}

// DOM registry for getElementById
let elements: Record<string, MockElement> = {};

function setupDOM() {
  elements = {};

  const fab = mockElement('debugFab');
  fab.classList.add('hidden');
  elements['debugFab'] = fab;

  const panel = mockElement('debugOverlayPanel');
  panel.classList.add('hidden');
  elements['debugOverlayPanel'] = panel;

  const log = mockElement('debugOverlayLog');
  elements['debugOverlayLog'] = log;

  const toggle = mockElement('debugOverlay') as MockElement & { checked: boolean; type: string };
  toggle.type = 'checkbox';
  toggle.checked = false;
  elements['debugOverlay'] = toggle;

  const copyBtn = mockElement('debugCopyBtn');
  elements['debugCopyBtn'] = copyBtn;

  const clearBtn = mockElement('debugClearBtn');
  elements['debugClearBtn'] = clearBtn;

  const collapseBtn = mockElement('debugCollapseBtn');
  elements['debugCollapseBtn'] = collapseBtn;

  return { fab, panel, log, toggle, copyBtn, clearBtn, collapseBtn };
}

vi.stubGlobal('document', {
  getElementById: (id: string) => elements[id] ?? null,
  createElement: (tag: string) => {
    const el = mockElement('');
    (el as Record<string, unknown>).tagName = tag.toUpperCase();
    return el;
  },
});

describe('debug panel — collapsible top panel (#208)', () => {
  beforeEach(() => {
    for (const k of Object.keys(localStore)) delete localStore[k];
    clipboardWriteText.mockClear();
    vi.resetModules();
  });

  it('FAB is hidden by default when debug is disabled', async () => {
    const { fab } = setupDOM();
    const { initDebugOverlay } = await import('../debug.js');
    initDebugOverlay();
    expect(fab.classList.contains('hidden')).toBe(true);
  });

  it('enabling debug shows FAB and hides panel', async () => {
    localStore['debugOverlay'] = 'true';
    const { fab, panel, toggle } = setupDOM();
    toggle.checked = true;
    const { initDebugOverlay } = await import('../debug.js');
    initDebugOverlay();
    expect(fab.classList.contains('hidden')).toBe(false);
    expect(panel.classList.contains('hidden')).toBe(true);
  });

  it('clicking FAB expands panel and hides FAB', async () => {
    localStore['debugOverlay'] = 'true';
    const { fab, panel, toggle } = setupDOM();
    toggle.checked = true;
    const { initDebugOverlay } = await import('../debug.js');
    initDebugOverlay();
    fab.click();
    expect(panel.classList.contains('hidden')).toBe(false);
    expect(fab.classList.contains('hidden')).toBe(true);
  });

  it('clicking collapse hides panel and shows FAB', async () => {
    localStore['debugOverlay'] = 'true';
    const { fab, panel, toggle, collapseBtn } = setupDOM();
    toggle.checked = true;
    const { initDebugOverlay } = await import('../debug.js');
    initDebugOverlay();
    // Expand first
    fab.click();
    expect(panel.classList.contains('hidden')).toBe(false);
    // Collapse
    collapseBtn.click();
    expect(panel.classList.contains('hidden')).toBe(true);
    expect(fab.classList.contains('hidden')).toBe(false);
  });

  it('clear button empties the log', async () => {
    localStore['debugOverlay'] = 'true';
    const { fab, log, toggle, clearBtn } = setupDOM();
    toggle.checked = true;
    const { initDebugOverlay } = await import('../debug.js');
    initDebugOverlay();
    fab.click();
    // console.log adds entries to the log
    console.log('test message for clear');
    expect(log.children.length).toBeGreaterThan(0);
    clearBtn.click();
    expect(log.children.length).toBe(0);
  });

  it('copy button calls clipboard.writeText', async () => {
    localStore['debugOverlay'] = 'true';
    const { fab, toggle, copyBtn } = setupDOM();
    toggle.checked = true;
    const { initDebugOverlay } = await import('../debug.js');
    initDebugOverlay();
    fab.click();
    console.log('copy test line');
    copyBtn.click();
    expect(clipboardWriteText).toHaveBeenCalled();
  });

  it('disabling debug via toggle hides both FAB and panel', async () => {
    localStore['debugOverlay'] = 'true';
    const { fab, panel, toggle } = setupDOM();
    toggle.checked = true;
    const { initDebugOverlay } = await import('../debug.js');
    initDebugOverlay();
    expect(fab.classList.contains('hidden')).toBe(false);
    // Disable
    toggle.checked = false;
    toggle.dispatchEvent({ type: 'change' });
    expect(fab.classList.contains('hidden')).toBe(true);
    expect(panel.classList.contains('hidden')).toBe(true);
  });
});
