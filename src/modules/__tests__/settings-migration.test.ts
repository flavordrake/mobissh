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

const { migrateSettings } = await import('../settings.js');

describe('settings-migration (#333)', () => {
  beforeEach(() => {
    storage.clear();
  });

  it('is exported and callable', () => {
    expect(typeof migrateSettings).toBe('function');
    expect(() => migrateSettings()).not.toThrow();
  });

  it('removes invalid imeDockPosition values', () => {
    storage.set('imeDockPosition', 'hover-top');
    migrateSettings();
    expect(storage.has('imeDockPosition')).toBe(false);
  });

  it('preserves valid imeDockPosition values', () => {
    storage.set('imeDockPosition', 'top');
    migrateSettings();
    expect(storage.get('imeDockPosition')).toBe('top');

    storage.set('imeDockPosition', 'bottom');
    migrateSettings();
    expect(storage.get('imeDockPosition')).toBe('bottom');
  });

  it('removes invalid imePreviewMode values', () => {
    storage.set('imePreviewMode', 'always');
    migrateSettings();
    expect(storage.has('imePreviewMode')).toBe(false);
  });

  it('preserves valid imePreviewMode values', () => {
    storage.set('imePreviewMode', 'true');
    migrateSettings();
    expect(storage.get('imePreviewMode')).toBe('true');
  });

  it('removes invalid imeMode values', () => {
    storage.set('imeMode', 'hybrid');
    migrateSettings();
    expect(storage.has('imeMode')).toBe(false);
  });

  it('preserves valid imeMode values', () => {
    storage.set('imeMode', 'ime');
    migrateSettings();
    expect(storage.get('imeMode')).toBe('ime');

    storage.set('imeMode', 'direct');
    migrateSettings();
    expect(storage.get('imeMode')).toBe('direct');
  });

  it('removes invalid keyControlsDock values', () => {
    storage.set('keyControlsDock', 'center');
    migrateSettings();
    expect(storage.has('keyControlsDock')).toBe(false);
  });

  it('preserves valid keyControlsDock values', () => {
    storage.set('keyControlsDock', 'left');
    migrateSettings();
    expect(storage.get('keyControlsDock')).toBe('left');
  });

  it('leaves missing keys alone (no default injection)', () => {
    migrateSettings();
    expect(storage.has('imeDockPosition')).toBe(false);
    expect(storage.has('imePreviewMode')).toBe(false);
    expect(storage.has('imeMode')).toBe(false);
    expect(storage.has('keyControlsDock')).toBe(false);
  });

  it('handles multiple invalid keys in one call', () => {
    storage.set('imeDockPosition', 'hover-top');
    storage.set('imeMode', 'hybrid');
    storage.set('keyControlsDock', 'center');
    migrateSettings();
    expect(storage.has('imeDockPosition')).toBe(false);
    expect(storage.has('imeMode')).toBe(false);
    expect(storage.has('keyControlsDock')).toBe(false);
  });
});
