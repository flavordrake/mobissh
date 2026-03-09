/**
 * Unit tests for Origin header validation (CSWSH prevention, issue #83).
 *
 * Tests the isOriginAllowed() function from server/origin.js.
 * That module has zero external dependencies so it runs without any mocking.
 */

import { describe, it, expect } from 'vitest';
import { createRequire } from 'node:module';

const req = createRequire(import.meta.url);
const { isOriginAllowed } = req('../../../server/origin.js') as {
  isOriginAllowed: (origin: string | undefined, host: string | undefined, allowlist: string[]) => boolean;
};

describe('isOriginAllowed (CSWSH prevention, #83)', () => {
  describe('same-origin', () => {
    it('allows when Origin host matches Host header', () => {
      expect(isOriginAllowed('http://localhost:8081', 'localhost:8081', [])).toBe(true);
    });

    it('allows https origin matching https host', () => {
      expect(isOriginAllowed('https://myapp.tailnet.ts.net', 'myapp.tailnet.ts.net', [])).toBe(true);
    });
  });

  describe('cross-origin', () => {
    it('rejects when Origin host does not match Host header', () => {
      expect(isOriginAllowed('http://evil.example.com', 'localhost:8081', [])).toBe(false);
    });

    it('rejects cross-origin even when Host is absent', () => {
      expect(isOriginAllowed('http://evil.example.com', undefined, [])).toBe(false);
    });

    it('rejects malformed Origin header', () => {
      expect(isOriginAllowed('not-a-url', 'localhost:8081', [])).toBe(false);
    });
  });

  describe('missing Origin header', () => {
    it('allows when Origin is absent (non-browser client)', () => {
      expect(isOriginAllowed(undefined, 'localhost:8081', [])).toBe(true);
    });

    it('allows when Origin is empty string', () => {
      expect(isOriginAllowed('', 'localhost:8081', [])).toBe(true);
    });
  });

  describe('allowlist', () => {
    it('allows an origin matching an allowlist entry', () => {
      expect(isOriginAllowed(
        'https://other.tailnet.ts.net',
        'localhost:8081',
        ['https://other.tailnet.ts.net'],
      )).toBe(true);
    });

    it('rejects an origin not in the allowlist and not same-origin', () => {
      expect(isOriginAllowed(
        'https://evil.example.com',
        'localhost:8081',
        ['https://other.tailnet.ts.net'],
      )).toBe(false);
    });

    it('skips malformed allowlist entries without crashing', () => {
      expect(isOriginAllowed(
        'http://localhost:8081',
        'localhost:8081',
        ['not-a-url', 'also-bad'],
      )).toBe(true);
    });
  });

  describe('TS_SERVE mode context', () => {
    it('same-origin still passes (TS_SERVE does not bypass origin check)', () => {
      // The origin check runs regardless of TS_SERVE; TS_SERVE only skips WS token auth.
      expect(isOriginAllowed('https://myapp.tailnet.ts.net', 'myapp.tailnet.ts.net', [])).toBe(true);
    });

    it('cross-origin is still rejected (TS_SERVE does not exempt cross-origin)', () => {
      expect(isOriginAllowed('https://evil.example.com', 'myapp.tailnet.ts.net', [])).toBe(false);
    });
  });
});
