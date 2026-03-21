import { describe, it, expect, beforeEach, vi } from 'vitest';

// Stub browser globals BEFORE any module imports

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

vi.stubGlobal('document', {
  getElementById: () => null,
  querySelector: () => null,
  addEventListener: vi.fn(),
  visibilityState: 'visible',
  hasFocus: () => true,
  documentElement: {
    style: { setProperty: vi.fn() },
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

vi.stubGlobal('window', {
  addEventListener: vi.fn(),
  visualViewport: null,
  outerHeight: 900,
});

// Track showNotification calls with full options
const mockShowNotification = vi.fn((_title: string, _options?: Record<string, unknown>) => {
  return Promise.resolve();
});

vi.stubGlobal('navigator', {
  serviceWorker: {
    ready: Promise.resolve({ showNotification: mockShowNotification }),
  },
});

vi.useFakeTimers();

const { fireNotification } = await import('../terminal.js');

describe('notification tag (#160)', () => {
  beforeEach(() => {
    mockShowNotification.mockClear();
  });

  it('passes tag: mobissh-agent to showNotification from terminal', async () => {
    fireNotification('MobiSSH', 'Build complete');
    // fireNotification uses navigator.serviceWorker.ready (microtask)
    await vi.advanceTimersByTimeAsync(10);

    expect(mockShowNotification).toHaveBeenCalledOnce();
    const [title, options] = mockShowNotification.mock.calls[0];
    expect(title).toBe('MobiSSH');
    expect(options).toHaveProperty('tag', 'mobissh-agent');
    expect(options).toHaveProperty('body', 'Build complete');
  });

  it('includes tag alongside body in every call', async () => {
    fireNotification('Custom Title', 'Deployment finished');
    await vi.advanceTimersByTimeAsync(10);

    expect(mockShowNotification).toHaveBeenCalledOnce();
    const [, options] = mockShowNotification.mock.calls[0];
    expect(options).toMatchObject({
      body: 'Deployment finished',
      tag: 'mobissh-agent',
    });
  });
});
