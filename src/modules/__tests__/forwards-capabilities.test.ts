/**
 * Red baseline for issue #499 — loadCapabilities() client-side caching + fallback.
 *
 * Covers:
 *   A6  loadCapabilities() is per-session cached (fetch called once across N calls)
 *   A7  loadCapabilities() falls back gracefully on 404
 *   A8  loadCapabilities() falls back on network error
 *
 * Pre-implementation: src/modules/forwards.ts does not exist. These tests
 * fail with "Cannot find module '../forwards.js'" — acceptable red baseline.
 */

import { describe, it, expect, beforeEach, vi, afterEach } from 'vitest';
import type { Capabilities } from '../types.js';

// Stub browser globals
vi.stubGlobal('localStorage', {
  getItem: () => null,
  setItem: () => {},
  removeItem: () => {},
  clear: () => {},
  length: 0,
  key: () => null,
});
vi.stubGlobal('location', { hostname: 'localhost' });

describe('forwards: loadCapabilities() (#499)', () => {
  let fetchSpy: ReturnType<typeof vi.fn>;
  let warnSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(async () => {
    // Reset the module cache so each test gets a fresh `_capabilitiesCache`
    // inside forwards.ts (assuming module-scoped cache, the standard PWA pattern).
    vi.resetModules();
    fetchSpy = vi.fn();
    vi.stubGlobal('fetch', fetchSpy);
    warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {});
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    warnSpy.mockRestore();
  });

  it('A6: calls fetch("/capabilities") exactly once across three calls', async () => {
    const payload: Capabilities = {
      version: 1,
      bridge: { version: 'test-1', hash: 'abc' },
      portForward: { local: true, remote: false, dynamic: false },
    };
    fetchSpy.mockResolvedValue(new Response(JSON.stringify(payload), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    }));

    const { loadCapabilities } = await import('../forwards.js');
    const a = await loadCapabilities();
    const b = await loadCapabilities();
    const c = await loadCapabilities();

    expect(fetchSpy).toHaveBeenCalledTimes(1);
    // All three calls observe the same (or structurally-equal) snapshot
    expect(a).toEqual(payload);
    expect(b).toEqual(payload);
    expect(c).toEqual(payload);
  });

  it('A6b: fetch is called against the same-origin /capabilities URL', async () => {
    fetchSpy.mockResolvedValue(new Response(JSON.stringify({
      version: 1,
      bridge: { version: 'x', hash: 'y' },
      portForward: { local: false, remote: false, dynamic: false },
    }), { status: 200 }));
    const { loadCapabilities } = await import('../forwards.js');
    await loadCapabilities();

    const url = fetchSpy.mock.calls[0]?.[0];
    expect(url).toMatch(/\/capabilities$/);
  });

  it('A7: 404 resolves to a safe fallback (does NOT reject)', async () => {
    fetchSpy.mockResolvedValue(new Response('Not found', { status: 404 }));

    const { loadCapabilities } = await import('../forwards.js');
    const caps = await loadCapabilities();

    expect(caps).toBeDefined();
    expect(caps.version).toBe(1);
    expect(caps.bridge).toBeDefined();
    expect(caps.bridge.version).toBe('unknown');
    expect(caps.portForward).toBeDefined();
    expect(caps.portForward.local).toBe(false);
    expect(caps.portForward.remote).toBe(false);
    expect(caps.portForward.dynamic).toBe(false);
  });

  it('A8: network error (TypeError: Failed to fetch) resolves to the same fallback', async () => {
    fetchSpy.mockRejectedValue(new TypeError('Failed to fetch'));

    const { loadCapabilities } = await import('../forwards.js');
    const caps = await loadCapabilities();

    expect(caps).toBeDefined();
    expect(caps.version).toBe(1);
    expect(caps.bridge.version).toBe('unknown');
    expect(caps.portForward.local).toBe(false);
    expect(caps.portForward.remote).toBe(false);
    expect(caps.portForward.dynamic).toBe(false);

    // Network error should be observable (warn ok) but NOT thrown
    // No unhandled rejection — the call awaited successfully
  });

  it('A8b: network error does NOT trigger any error dialog (warn ok)', async () => {
    // The spec explicitly forbids showing an error dialog for the
    // capabilities load failure. We approximate by asserting no
    // showErrorDialog import is invoked. Since forwards.ts may not import it
    // at all (preferred), this also passes by simple absence — we only
    // check that, post-call, console.warn is the loudest channel used.
    fetchSpy.mockRejectedValue(new TypeError('Failed to fetch'));
    const errSpy = vi.spyOn(console, 'error').mockImplementation(() => {});

    const { loadCapabilities } = await import('../forwards.js');
    await loadCapabilities();

    // console.error would indicate a higher-severity surfacing than the
    // spec allows — A8 says console.warn is acceptable.
    expect(errSpy).not.toHaveBeenCalled();
    errSpy.mockRestore();
  });
});
