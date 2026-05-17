/**
 * Red baseline for issue #499 — fwd_local_* wire protocol.
 *
 * Covers:
 *   D1   Client → server message types exist with correct shapes
 *   D2   Server → client message types exist with correct shapes
 *   D3   fwd_local_error is delivered as a WS message, not a connection drop
 *   D4   Unknown fwd_local_* types from the server are dropped without crash
 *   D5   ServerMessage / ClientMessage unions include the new shapes
 *   EC2  fwd_local_* server messages received BEFORE capabilities load are dropped
 *   EC8  Malformed base64 in fwd_local_data closes the channel, not the WS
 *
 * Pre-implementation: forwards.ts is missing → most tests fail on import.
 * The D5 type-shape tests are vitest-runtime but assert that the union
 * literals are accepted by tsc — those compile but fail at runtime because
 * the discriminator-based runtime guards in forwards.ts don't exist yet.
 */

import { describe, it, expect, beforeEach, vi, afterEach } from 'vitest';
import type { ClientMessage, ServerMessage } from '../types.js';

vi.stubGlobal('localStorage', {
  getItem: () => null,
  setItem: () => {},
  removeItem: () => {},
  clear: () => {},
  length: 0,
  key: () => null,
});
vi.stubGlobal('location', { hostname: 'localhost' });

describe('forwards protocol shapes (#499)', () => {

  beforeEach(() => {
    vi.resetModules();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    vi.stubGlobal('localStorage', {
      getItem: () => null, setItem: () => {}, removeItem: () => {},
      clear: () => {}, length: 0, key: () => null,
    });
    vi.stubGlobal('location', { hostname: 'localhost' });
  });

  // ── D5: types compile + sentinels present ────────────────────────────────

  describe('D5: types.ts includes fwd_local_* discriminated variants', () => {
    it('ClientMessage union accepts every D1 variant', () => {
      const variants: ClientMessage[] = [
        { type: 'fwd_local_listen', id: 'i', srcPort: 8080, dstHost: 'h', dstPort: 80 },
        { type: 'fwd_local_data', id: 'i', channelId: 'c', dir: 'out', b64: 'AA==' },
        { type: 'fwd_local_channel_close', id: 'i', channelId: 'c' },
        { type: 'fwd_local_close', id: 'i' },
      ];
      expect(variants.length).toBe(4);
    });

    it('ServerMessage union accepts every D2 variant', () => {
      const variants: ServerMessage[] = [
        { type: 'fwd_local_ready', id: 'i', srcPort: 8080, listenAddr: '127.0.0.1' },
        { type: 'fwd_local_accept', id: 'i', channelId: 'c', peer: { host: '1.2.3.4', port: 12345 } },
        { type: 'fwd_local_data', id: 'i', channelId: 'c', dir: 'in', b64: 'AA==' },
        { type: 'fwd_local_channel_close', id: 'i', channelId: 'c', reason: 'eof' },
        { type: 'fwd_local_error', id: 'i', code: 'eaddrinuse', message: 'in use' },
        { type: 'fwd_local_closed', id: 'i', reason: 'user' },
      ];
      expect(variants.length).toBe(6);
    });

    it('types.ts carries the [FWD_LOCAL_SERVER_MESSAGE] sync sentinel', async () => {
      const { readFileSync } = await import('node:fs');
      const { resolve } = await import('node:path');
      const src = readFileSync(resolve(__dirname, '../types.ts'), 'utf-8');
      expect(src).toContain('[FWD_LOCAL_SERVER_MESSAGE]');
      expect(src).toContain('[FWD_LOCAL_CLIENT_MESSAGE]');
    });
  });

  // ── D1/D2 runtime: known frames are routed to the module's handler ───────

  describe('D1/D2: handleServerForwardMessage routes known fwd_local_* types', () => {
    it('routes fwd_local_ready by id without throwing', async () => {
      const mod = await import('../forwards.js');
      // applyCapabilities so the handler is "armed" — EC2 requires the
      // unarmed handler to drop messages, but here we want the happy path.
      mod.applyCapabilities({
        version: 1, bridge: { version: 't', hash: 'h' },
        portForward: { local: true, remote: false, dynamic: false },
      });
      expect(() => mod.handleServerForwardMessage({
        type: 'fwd_local_ready', id: 'F1', srcPort: 8080, listenAddr: '127.0.0.1',
      })).not.toThrow();
    });

    it('routes fwd_local_error without dropping the WS (D3)', async () => {
      const mod = await import('../forwards.js');
      mod.applyCapabilities({
        version: 1, bridge: { version: 't', hash: 'h' },
        portForward: { local: true, remote: false, dynamic: false },
      });
      // Crucially: handleServerForwardMessage must not throw, not close any
      // WS, and not detach the message listener. The WS lifetime is owned
      // by connection.ts — forwards.ts must stay a pure protocol consumer.
      expect(() => mod.handleServerForwardMessage({
        type: 'fwd_local_error', id: 'F1', code: 'eaddrinuse', message: 'bind failed',
      })).not.toThrow();
    });

    it('D3: fwd_local_error codes include the documented stable values', async () => {
      // These are the values the spec REQUIRES the server emit. The client
      // must therefore recognize at least these three.
      const mod = await import('../forwards.js');
      const codes = mod.getKnownForwardErrorCodes() as string[];
      expect(codes).toContain('eaddrinuse');
      expect(codes).toContain('forward_failed');
      expect(codes).toContain('not_supported');
    });
  });

  // ── D4: unknown types ────────────────────────────────────────────────────

  describe('D4: unknown fwd_local_* types do not crash the dispatcher', () => {
    it('handleServerForwardMessage ignores unknown types without throwing', async () => {
      const mod = await import('../forwards.js');
      mod.applyCapabilities({
        version: 1, bridge: { version: 't', hash: 'h' },
        portForward: { local: true, remote: false, dynamic: false },
      });
      // Cast through unknown — at runtime this is a valid forward path
      // because the server's default fall-through emits a generic `error`
      // message that the client should not match here either.
      const bogus = { type: 'fwd_local_bogus', id: 'x' } as unknown as ServerMessage;
      expect(() => mod.handleServerForwardMessage(bogus)).not.toThrow();
    });
  });

  // ── EC2: dropped if capabilities not loaded ──────────────────────────────

  describe('EC2: fwd_local_* messages before capabilities load are dropped', () => {
    it('handleServerForwardMessage(fwd_local_accept) before capabilities does NOT create a forward entry', async () => {
      const mod = await import('../forwards.js');
      // Note: NO applyCapabilities() call — the EC2 case
      mod.handleServerForwardMessage({
        type: 'fwd_local_accept', id: 'F-rogue', channelId: 'C1',
        peer: { host: '1.2.3.4', port: 12345 },
      });
      expect(mod.listForwards().length).toBe(0);
    });

    it('handleServerForwardMessage(fwd_local_ready) before capabilities does NOT reveal the panel', async () => {
      const mod = await import('../forwards.js');
      // No applyCapabilities — getCapabilities() returns null/undefined
      mod.handleServerForwardMessage({
        type: 'fwd_local_ready', id: 'F-rogue', srcPort: 8080, listenAddr: '127.0.0.1',
      });
      // The forwards module must not magically populate capabilities from
      // a stray server frame.
      expect(mod.getCapabilities()).toBeFalsy();
    });
  });

  // ── EC8: malformed base64 in fwd_local_data closes the channel ───────────

  describe('EC8: malformed base64 in fwd_local_data', () => {
    it('decodeForwardData throws or returns null on malformed b64 (server uses this to send fwd_local_channel_close)', async () => {
      // This unit test is the CLIENT-side analog: the implementation must
      // expose a reusable decoder that returns null (or throws) for input
      // that won't decode. The SERVER reuses the same predicate to close
      // the channel with reason: 'bad_payload'.
      const mod = await import('../forwards.js');
      // "!!!" is not a legal base64 char set
      const result = mod.tryDecodeBase64('!!!');
      expect(result).toBeNull();
    });

    it('valid b64 round-trips back to original bytes', async () => {
      const mod = await import('../forwards.js');
      const out = mod.tryDecodeBase64('aGVsbG8='); // "hello"
      expect(out).not.toBeNull();
      // Compare as string for easy reading
      const s = new TextDecoder().decode(out as Uint8Array);
      expect(s).toBe('hello');
    });
  });
});
