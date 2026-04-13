import { describe, it, expect, beforeEach, vi } from 'vitest';
import { readFileSync } from 'fs';
import { join } from 'path';

/**
 * Tests that the service worker respects Cache-Control: no-store by NOT caching
 * responses that include that header. This is a security requirement — index.html
 * contains a ws-token meta tag that must never persist to disk cache.
 */

// Read sw.js source to verify the check exists in the actual code
const swSource = readFileSync(join(__dirname, '../../../public/sw.js'), 'utf-8');

describe('sw.js Cache-Control: no-store', () => {
  it('should check Cache-Control header before calling cache.put', () => {
    // The fetch handler must inspect Cache-Control before caching
    // Look for the pattern: check no-store BEFORE cache.put
    const hasCacheControlCheck = /headers\.get\(['"]Cache-Control['"]\)/.test(swSource);
    const hasNoStoreCheck = /no-store/.test(swSource);

    expect(hasCacheControlCheck).toBe(true);
    expect(hasNoStoreCheck).toBe(true);
  });

  it('should not unconditionally cache all ok responses', () => {
    // The old pattern was: if (response.ok) { cache.put(...) }
    // The new pattern must have a no-store guard between response.ok and cache.put
    //
    // Extract the fetch handler section (between 'fetch' listener and the closing)
    const fetchSection = swSource.match(
      /addEventListener\('fetch'[\s\S]*?if\s*\(response\.ok\)\s*\{([\s\S]*?)return response/
    );
    expect(fetchSection).not.toBeNull();

    const cacheBlock = fetchSection![1];
    // The block between response.ok and cache.put must contain a no-store check
    const hasGuard = /no-store/.test(cacheBlock);
    expect(hasGuard).toBe(true);
  });

  it('should still have cache.put for responses without no-store', () => {
    // cache.put should still exist — it's needed for cacheable responses
    const hasCachePut = /cache\.put/.test(swSource);
    expect(hasCachePut).toBe(true);
  });
});
