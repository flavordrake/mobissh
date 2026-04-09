import { describe, it, expect, vi } from 'vitest';
import {
  probeConnectLayers,
  WS_CONNECTING,
  WS_OPEN,
  WS_CLOSING,
  WS_CLOSED,
} from '../connect-probe.js';

// Shared helpers

function makeResponse(ok: boolean, status: number): Response {
  return { ok, status } as unknown as Response;
}

function okFetch(): (url: string, init: RequestInit) => Promise<Response> {
  return vi.fn(() => Promise.resolve(makeResponse(true, 200)));
}

function failFetch(err: Error): (url: string, init: RequestInit) => Promise<Response> {
  return vi.fn(() => Promise.reject(err));
}

function slowFetch(delayMs: number): (url: string, init: RequestInit) => Promise<Response> {
  return vi.fn((_url, init: RequestInit) => new Promise((resolve, reject) => {
    const signal = init.signal;
    const timer = setTimeout(() => { resolve(makeResponse(true, 200)); }, delayMs);
    signal?.addEventListener('abort', () => {
      clearTimeout(timer);
      const err = new Error('aborted');
      err.name = 'AbortError';
      reject(err);
    });
  }));
}

describe('probeConnectLayers', () => {
  describe('layer 1: radio', () => {
    it('reports offline when navigator.onLine is false and short-circuits', async () => {
      const fetchImpl = vi.fn();
      const lines = await probeConnectLayers({
        onLine: false,
        fetchImpl,
        ws: { readyState: WS_CONNECTING },
      });

      expect(lines).toHaveLength(1);
      expect(lines[0]!.layer).toBe('radio');
      expect(lines[0]!.ok).toBe(false);
      expect(lines[0]!.message).toMatch(/offline/i);
      // Must not proceed to HTTP when radio is off
      expect(fetchImpl).not.toHaveBeenCalled();
    });

    it('reports online and proceeds to HTTP when navigator.onLine is true', async () => {
      const lines = await probeConnectLayers({
        onLine: true,
        fetchImpl: okFetch(),
        ws: { readyState: WS_OPEN },
      });

      expect(lines[0]!.layer).toBe('radio');
      expect(lines[0]!.ok).toBe(true);
      expect(lines.length).toBeGreaterThan(1);
    });
  });

  describe('layer 2: HTTP to MobiSSH', () => {
    it('reports ok on HTTP 200 and proceeds to WebSocket layer', async () => {
      const lines = await probeConnectLayers({
        onLine: true,
        fetchImpl: okFetch(),
        ws: { readyState: WS_OPEN },
      });

      expect(lines[1]!.layer).toBe('http');
      expect(lines[1]!.ok).toBe(true);
      expect(lines[1]!.message).toMatch(/200/);
      // Proceeds to websocket layer
      expect(lines).toHaveLength(3);
      expect(lines[2]!.layer).toBe('websocket');
    });

    it('reports unhealthy when HTTP returns non-2xx and short-circuits', async () => {
      const fetchImpl = vi.fn(() => Promise.resolve(makeResponse(false, 503)));
      const lines = await probeConnectLayers({
        onLine: true,
        fetchImpl,
        ws: { readyState: WS_OPEN },
      });

      expect(lines[1]!.layer).toBe('http');
      expect(lines[1]!.ok).toBe(false);
      expect(lines[1]!.message).toMatch(/503/);
      expect(lines[1]!.message).toMatch(/unhealthy/);
      // Must not proceed to WS if HTTP failed
      expect(lines).toHaveLength(2);
    });

    it('reports timeout when fetch does not respond in time', async () => {
      const lines = await probeConnectLayers({
        onLine: true,
        fetchImpl: slowFetch(10_000),
        ws: { readyState: WS_CONNECTING },
        httpTimeoutMs: 50,
      });

      expect(lines[1]!.layer).toBe('http');
      expect(lines[1]!.ok).toBe(false);
      expect(lines[1]!.message).toMatch(/No HTTP response/);
      expect(lines[1]!.message).toMatch(/Tailscale/);
      expect(lines).toHaveLength(2);
    });

    it('reports generic failure on network error (not timeout)', async () => {
      const lines = await probeConnectLayers({
        onLine: true,
        fetchImpl: failFetch(new TypeError('Failed to fetch')),
        ws: { readyState: WS_CONNECTING },
      });

      expect(lines[1]!.layer).toBe('http');
      expect(lines[1]!.ok).toBe(false);
      expect(lines[1]!.message).toMatch(/failed/);
      expect(lines[1]!.message).toMatch(/Tailscale/);
    });

    it('uses custom versionUrl when provided', async () => {
      const fetchImpl = okFetch();
      await probeConnectLayers({
        onLine: true,
        fetchImpl,
        ws: { readyState: WS_OPEN },
        versionUrl: 'https://custom.example.com/v',
      });

      expect(fetchImpl).toHaveBeenCalledWith('https://custom.example.com/v', expect.any(Object));
    });
  });

  describe('layer 3: WebSocket readyState', () => {
    it('reports stuck handshake when WS is still CONNECTING', async () => {
      const lines = await probeConnectLayers({
        onLine: true,
        fetchImpl: okFetch(),
        ws: { readyState: WS_CONNECTING },
      });

      expect(lines[2]!.layer).toBe('websocket');
      expect(lines[2]!.ok).toBe(false);
      expect(lines[2]!.message).toMatch(/handshake is stuck/);
      expect(lines[2]!.message).toMatch(/remote SSH host/);
    });

    it('reports waiting on SSH auth when WS is OPEN', async () => {
      const lines = await probeConnectLayers({
        onLine: true,
        fetchImpl: okFetch(),
        ws: { readyState: WS_OPEN },
      });

      expect(lines[2]!.layer).toBe('websocket');
      expect(lines[2]!.ok).toBe(true);
      expect(lines[2]!.message).toMatch(/SSH authentication/);
    });

    it('reports closed handshake when WS is CLOSING', async () => {
      const lines = await probeConnectLayers({
        onLine: true,
        fetchImpl: okFetch(),
        ws: { readyState: WS_CLOSING },
      });

      expect(lines[2]!.ok).toBe(false);
      expect(lines[2]!.message).toMatch(/closed before SSH ready/);
      expect(lines[2]!.message).toMatch(/2/); // readyState echoed
    });

    it('reports closed handshake when WS is CLOSED', async () => {
      const lines = await probeConnectLayers({
        onLine: true,
        fetchImpl: okFetch(),
        ws: { readyState: WS_CLOSED },
      });

      expect(lines[2]!.ok).toBe(false);
      expect(lines[2]!.message).toMatch(/closed before SSH ready/);
      expect(lines[2]!.message).toMatch(/3/);
    });

    it('reports "WebSocket not started" when ws is null despite HTTP success', async () => {
      const lines = await probeConnectLayers({
        onLine: true,
        fetchImpl: okFetch(),
        ws: null,
      });

      expect(lines[2]!.layer).toBe('websocket');
      expect(lines[2]!.ok).toBe(false);
      expect(lines[2]!.message).toMatch(/not started/);
      expect(lines[2]!.message).toMatch(/bug/);
    });
  });

  describe('cascade ordering', () => {
    it('always produces lines in order: radio → http → websocket', async () => {
      const lines = await probeConnectLayers({
        onLine: true,
        fetchImpl: okFetch(),
        ws: { readyState: WS_OPEN },
      });

      expect(lines.map(l => l.layer)).toEqual(['radio', 'http', 'websocket']);
    });

    it('short-circuits at first failure — radio off → only one line', async () => {
      const lines = await probeConnectLayers({
        onLine: false,
        fetchImpl: okFetch(),
        ws: { readyState: WS_OPEN },
      });

      expect(lines).toHaveLength(1);
    });

    it('short-circuits at first failure — http fail → exactly two lines', async () => {
      const lines = await probeConnectLayers({
        onLine: true,
        fetchImpl: failFetch(new TypeError('net')),
        ws: { readyState: WS_OPEN },
      });

      expect(lines).toHaveLength(2);
    });

    it('full cascade completes when radio and http both pass', async () => {
      const lines = await probeConnectLayers({
        onLine: true,
        fetchImpl: okFetch(),
        ws: { readyState: WS_OPEN },
      });

      expect(lines).toHaveLength(3);
    });
  });
});
