import { describe, it, expect, beforeEach, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

/**
 * IME dock position cycling tests (#255).
 *
 * Issue #255 expands the dock button from a simple top/bottom toggle to a
 * 5-position cycle: hover-top, hover-bottom, cursor-follow, dock-above,
 * dock-below. These tests express the expected behavior for that feature.
 *
 * Tests are split into two groups:
 *   1. API tests — import the new exports (DockPosition type, cycle/get/set
 *      functions) and verify runtime behavior via the localStorage mock.
 *   2. Structural tests — read ime.ts source and verify positioning logic
 *      for cursor-follow, dock-above, and dock-below modes.
 */

// ── Source-based structural tests ───────────────────────────────────────────

const imeSrc = readFileSync(resolve(__dirname, '../ime.ts'), 'utf-8');

describe('DockPosition type has 5 values (#255)', () => {
  it('source defines hover-top as a dock position', () => {
    expect(imeSrc).toContain("'hover-top'");
  });

  it('source defines hover-bottom as a dock position', () => {
    expect(imeSrc).toContain("'hover-bottom'");
  });

  it('source defines cursor-follow as a dock position', () => {
    expect(imeSrc).toContain("'cursor-follow'");
  });

  it('source defines dock-above as a dock position', () => {
    expect(imeSrc).toContain("'dock-above'");
  });

  it('source defines dock-below as a dock position', () => {
    expect(imeSrc).toContain("'dock-below'");
  });
});

// ── API tests via module import ─────────────────────────────────────────────

const storage = new Map<string, string>();
const localStorageMock = {
  getItem: (key: string) => storage.get(key) ?? null,
  setItem: (key: string, value: string) => { storage.set(key, value); },
  removeItem: (key: string) => { storage.delete(key); },
  clear: () => { storage.clear(); },
  get length() { return storage.size; },
  key: (_i: number) => null as string | null,
};
vi.stubGlobal('localStorage', localStorageMock);
vi.stubGlobal('location', { hostname: 'localhost', host: 'localhost:8081' });

vi.stubGlobal('document', {
  getElementById: () => null,
  querySelector: () => null,
  addEventListener: vi.fn(),
  visibilityState: 'visible',
  documentElement: {
    style: { setProperty: vi.fn() },
    dataset: {},
    classList: { toggle: vi.fn(), add: vi.fn(), remove: vi.fn() },
  },
  createElement: vi.fn(() => ({
    className: '',
    textContent: '',
    innerHTML: '',
    appendChild: vi.fn(),
    addEventListener: vi.fn(),
    querySelector: vi.fn(),
  })),
  fonts: { ready: Promise.resolve() },
  body: { appendChild: vi.fn(), classList: { add: vi.fn(), remove: vi.fn(), toggle: vi.fn() } },
});

vi.stubGlobal('window', {
  addEventListener: vi.fn(),
  visualViewport: null,
  outerHeight: 900,
  innerHeight: 900,
});

vi.stubGlobal('Notification', { permission: 'granted' });
vi.stubGlobal('getComputedStyle', () => ({ getPropertyValue: () => '' }));

const {
  DOCK_POSITIONS,
  cycleDockPosition,
  getDockPosition,
  setDockPosition,
} = await import('../ime.js');

describe('cycleDockPosition cycles through all 5 positions (#255)', () => {
  beforeEach(() => {
    storage.clear();
  });

  it('DOCK_POSITIONS contains exactly 5 entries', () => {
    expect(DOCK_POSITIONS).toHaveLength(5);
  });

  it('DOCK_POSITIONS lists positions in defined order', () => {
    expect([...DOCK_POSITIONS]).toEqual([
      'hover-top',
      'hover-bottom',
      'cursor-follow',
      'dock-above',
      'dock-below',
    ]);
  });

  it('cycles from hover-top to hover-bottom', () => {
    setDockPosition('hover-top');
    expect(cycleDockPosition()).toBe('hover-bottom');
  });

  it('cycles from hover-bottom to cursor-follow', () => {
    setDockPosition('hover-bottom');
    expect(cycleDockPosition()).toBe('cursor-follow');
  });

  it('cycles from cursor-follow to dock-above', () => {
    setDockPosition('cursor-follow');
    expect(cycleDockPosition()).toBe('dock-above');
  });

  it('cycles from dock-above to dock-below', () => {
    setDockPosition('dock-above');
    expect(cycleDockPosition()).toBe('dock-below');
  });

  it('wraps from dock-below back to hover-top', () => {
    setDockPosition('dock-below');
    expect(cycleDockPosition()).toBe('hover-top');
  });
});

describe('getDockPosition returns persisted value (#255)', () => {
  beforeEach(() => {
    storage.clear();
  });

  it('defaults to hover-top when nothing persisted', () => {
    expect(getDockPosition()).toBe('hover-top');
  });

  it('returns value from localStorage', () => {
    storage.set('imeDockPosition', 'cursor-follow');
    expect(getDockPosition()).toBe('cursor-follow');
  });

  it('ignores invalid localStorage values and returns default', () => {
    storage.set('imeDockPosition', 'invalid-value');
    expect(getDockPosition()).toBe('hover-top');
  });
});

describe('setDockPosition persists to localStorage (#255)', () => {
  beforeEach(() => {
    storage.clear();
  });

  it('persists hover-bottom to localStorage', () => {
    setDockPosition('hover-bottom');
    expect(storage.get('imeDockPosition')).toBe('hover-bottom');
  });

  it('persists cursor-follow to localStorage', () => {
    setDockPosition('cursor-follow');
    expect(storage.get('imeDockPosition')).toBe('cursor-follow');
  });

  it('persists dock-above to localStorage', () => {
    setDockPosition('dock-above');
    expect(storage.get('imeDockPosition')).toBe('dock-above');
  });

  it('persists dock-below to localStorage', () => {
    setDockPosition('dock-below');
    expect(storage.get('imeDockPosition')).toBe('dock-below');
  });

  it('getDockPosition reflects persisted value after set', () => {
    setDockPosition('dock-above');
    expect(getDockPosition()).toBe('dock-above');
  });
});

describe('cursor-follow mode debounces repositioning (#255)', () => {
  it('source contains a debounce guard for cursor-follow repositioning', () => {
    // cursor-follow should debounce _positionIME calls at 200ms
    const hasCursorFollowDebounce = imeSrc.includes('cursor-follow')
      && imeSrc.includes('200');
    expect(hasCursorFollowDebounce).toBe(true);
  });

  it('source references cursor position tracking for cursor-follow mode', () => {
    // cursor-follow mode must read terminal cursor position to reposition
    const match = imeSrc.match(/cursor-follow[^}]*cursorY/s)
      ?? imeSrc.match(/cursorY[^}]*cursor-follow/s);
    expect(match, 'cursor-follow should reference cursorY for positioning').toBeTruthy();
  });
});

describe('dock-above positions textarea above #terminal element (#255)', () => {
  it('source references terminal element for dock-above positioning', () => {
    const match = imeSrc.match(/dock-above[^}]*terminal/s)
      ?? imeSrc.match(/terminal[^}]*dock-above/s);
    expect(match, 'dock-above should reference terminal element').toBeTruthy();
  });

  it('dock-above places textarea above the terminal', () => {
    // The positioning logic should set bottom relative to terminal top
    const match = imeSrc.match(/dock-above[^}]*\.getBoundingClientRect/s)
      ?? imeSrc.match(/getBoundingClientRect[^}]*dock-above/s);
    expect(match, 'dock-above should use getBoundingClientRect for positioning').toBeTruthy();
  });
});

describe('dock-below positions textarea below #terminal element (#255)', () => {
  it('source references terminal element for dock-below positioning', () => {
    const match = imeSrc.match(/dock-below[^}]*terminal/s)
      ?? imeSrc.match(/terminal[^}]*dock-below/s);
    expect(match, 'dock-below should reference terminal element').toBeTruthy();
  });

  it('dock-below places textarea below the terminal', () => {
    // The positioning logic should set top relative to terminal bottom
    const match = imeSrc.match(/dock-below[^}]*\.getBoundingClientRect/s)
      ?? imeSrc.match(/getBoundingClientRect[^}]*dock-below/s);
    expect(match, 'dock-below should use getBoundingClientRect for positioning').toBeTruthy();
  });
});
