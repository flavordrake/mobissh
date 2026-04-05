import { describe, it, expect, beforeEach, vi } from 'vitest';

/**
 * IME dock position cycling tests.
 *
 * Only two positions remain: hover-top, hover-bottom.
 * cursor-follow, dock-above, dock-below were removed due to
 * complications with invisible positioning and panel navigation bugs.
 */

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

describe('cycleDockPosition cycles through 2 positions', () => {
  beforeEach(() => {
    storage.clear();
  });

  it('DOCK_POSITIONS contains exactly 2 entries', () => {
    expect(DOCK_POSITIONS).toHaveLength(2);
  });

  it('DOCK_POSITIONS lists positions in defined order', () => {
    expect([...DOCK_POSITIONS]).toEqual([
      'hover-top',
      'hover-bottom',
    ]);
  });

  it('cycles from hover-top to hover-bottom', () => {
    setDockPosition('hover-top');
    expect(cycleDockPosition()).toBe('hover-bottom');
  });

  it('wraps from hover-bottom back to hover-top', () => {
    setDockPosition('hover-bottom');
    expect(cycleDockPosition()).toBe('hover-top');
  });
});

describe('getDockPosition returns persisted value', () => {
  beforeEach(() => {
    storage.clear();
  });

  it('defaults to hover-top when nothing persisted', () => {
    expect(getDockPosition()).toBe('hover-top');
  });

  it('returns hover-bottom from localStorage', () => {
    storage.set('imeDockPosition', 'hover-bottom');
    expect(getDockPosition()).toBe('hover-bottom');
  });

  it('ignores invalid localStorage values and returns default', () => {
    storage.set('imeDockPosition', 'invalid-value');
    expect(getDockPosition()).toBe('hover-top');
  });

  it('falls back to hover-top for removed positions', () => {
    storage.set('imeDockPosition', 'cursor-follow');
    expect(getDockPosition()).toBe('hover-top');
  });
});

describe('setDockPosition persists to localStorage', () => {
  beforeEach(() => {
    storage.clear();
  });

  it('persists hover-top to localStorage', () => {
    setDockPosition('hover-top');
    expect(storage.get('imeDockPosition')).toBe('hover-top');
  });

  it('persists hover-bottom to localStorage', () => {
    setDockPosition('hover-bottom');
    expect(storage.get('imeDockPosition')).toBe('hover-bottom');
  });

  it('getDockPosition reflects persisted value after set', () => {
    setDockPosition('hover-bottom');
    expect(getDockPosition()).toBe('hover-bottom');
  });
});
