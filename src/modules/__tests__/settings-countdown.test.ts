import { describe, it, expect, beforeEach, vi } from 'vitest';

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
  getPreviewTimeout,
  setPreviewTimeout,
  getPreviewIdleDelay,
  setPreviewIdleDelay,
  PREVIEW_DURATIONS,
  PREVIEW_IDLE_DELAYS,
} = await import('../ime.js');

describe('settings-countdown (#181)', () => {
  beforeEach(() => {
    storage.clear();
  });

  describe('PREVIEW_DURATIONS', () => {
    it('contains expected duration values', () => {
      expect(PREVIEW_DURATIONS).toContain(3000);
      expect(PREVIEW_DURATIONS).toContain(5000);
      expect(PREVIEW_DURATIONS).toContain(10000);
      expect(PREVIEW_DURATIONS).toContain(Infinity);
    });
  });

  describe('PREVIEW_IDLE_DELAYS', () => {
    it('contains expected idle delay values', () => {
      expect(PREVIEW_IDLE_DELAYS).toContain(1000);
      expect(PREVIEW_IDLE_DELAYS).toContain(1500);
      expect(PREVIEW_IDLE_DELAYS).toContain(2000);
      expect(PREVIEW_IDLE_DELAYS).toContain(3000);
    });
  });

  describe('getPreviewTimeout / setPreviewTimeout', () => {
    it('defaults to 3000 when no localStorage value', () => {
      expect(getPreviewTimeout()).toBe(3000);
    });

    it('persists value to localStorage on set', () => {
      setPreviewTimeout(5000);
      expect(storage.get('imePreviewTimeout')).toBe('5000');
    });

    it('returns persisted value after set', () => {
      setPreviewTimeout(10000);
      expect(getPreviewTimeout()).toBe(10000);
    });

    it('persists Infinity as string', () => {
      setPreviewTimeout(Infinity);
      expect(storage.get('imePreviewTimeout')).toBe('Infinity');
    });

    it('returns Infinity after setting Infinity', () => {
      setPreviewTimeout(Infinity);
      expect(getPreviewTimeout()).toBe(Infinity);
    });
  });

  describe('getPreviewIdleDelay / setPreviewIdleDelay', () => {
    it('defaults to 1500 when no localStorage value', () => {
      expect(getPreviewIdleDelay()).toBe(1500);
    });

    it('persists value to localStorage on set', () => {
      setPreviewIdleDelay(2000);
      expect(storage.get('imePreviewIdleDelay')).toBe('2000');
    });

    it('returns persisted value after set', () => {
      setPreviewIdleDelay(3000);
      expect(getPreviewIdleDelay()).toBe(3000);
    });

    it('loads from localStorage on get', () => {
      storage.set('imePreviewIdleDelay', '1000');
      expect(getPreviewIdleDelay()).toBe(1000);
    });
  });
});
