import { describe, it, expect, beforeEach, vi, afterEach } from 'vitest';

// Mock localStorage before importing modules
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
});

vi.stubGlobal('Notification', { permission: 'granted' });
vi.stubGlobal('getComputedStyle', () => ({ getPropertyValue: () => '' }));

const {
  DOCK_POSITIONS,
  getDockPosition,
  setDockPosition,
  cycleDockPosition,
  CURSOR_FOLLOW_DEBOUNCE_MS,
} = await import('../ime.js');

describe('ime-dock (#255)', () => {
  beforeEach(() => {
    storage.clear();
    // Reset to default
    setDockPosition('hover-top');
  });

  describe('DOCK_POSITIONS', () => {
    it('contains all 5 dock modes', () => {
      expect(DOCK_POSITIONS).toEqual([
        'hover-top',
        'hover-bottom',
        'cursor-follow',
        'dock-above',
        'dock-below',
      ]);
    });
  });

  describe('getDockPosition / setDockPosition', () => {
    it('defaults to hover-top when no localStorage value', () => {
      storage.clear();
      expect(getDockPosition()).toBe('hover-top');
    });

    it('persists value to localStorage on set', () => {
      setDockPosition('dock-below');
      expect(storage.get('imeDockPosition')).toBe('dock-below');
    });

    it('returns persisted value after set', () => {
      setDockPosition('cursor-follow');
      expect(getDockPosition()).toBe('cursor-follow');
    });

    it('loads from localStorage on get', () => {
      storage.set('imeDockPosition', 'dock-above');
      expect(getDockPosition()).toBe('dock-above');
    });

    it('falls back to hover-top for invalid localStorage value', () => {
      storage.set('imeDockPosition', 'invalid-value');
      expect(getDockPosition()).toBe('hover-top');
    });
  });

  describe('cycleDockPosition', () => {
    it('cycles through all 5 modes in order', () => {
      setDockPosition('hover-top');
      cycleDockPosition();
      expect(getDockPosition()).toBe('hover-bottom');

      cycleDockPosition();
      expect(getDockPosition()).toBe('cursor-follow');

      cycleDockPosition();
      expect(getDockPosition()).toBe('dock-above');

      cycleDockPosition();
      expect(getDockPosition()).toBe('dock-below');

      cycleDockPosition();
      expect(getDockPosition()).toBe('hover-top');
    });

    it('persists each cycled value to localStorage', () => {
      setDockPosition('hover-top');
      cycleDockPosition();
      expect(storage.get('imeDockPosition')).toBe('hover-bottom');
    });
  });

  describe('cursor-follow debounce', () => {
    beforeEach(() => {
      vi.useFakeTimers();
    });
    afterEach(() => {
      vi.useRealTimers();
    });

    it('debounce timer constant is 200ms', () => {
      expect(CURSOR_FOLLOW_DEBOUNCE_MS).toBe(200);
    });
  });
});
