/**
 * Unit tests for dynamic manifest name rewriting (#131).
 *
 * Tests the rewriteManifest() function from server/index.js with a
 * custom name parameter for multi-install PWA support.
 */

import { describe, it, expect } from 'vitest';
import { createRequire } from 'node:module';

const req = createRequire(import.meta.url);
const { rewriteManifest } = req('../../../server/manifest.js') as {
  rewriteManifest: (buf: Buffer, customName?: string) => Buffer;
};

const DEFAULT_MANIFEST = JSON.stringify({
  name: 'MobiSSH',
  short_name: 'MobiSSH',
  description: 'Mobile-first SSH PWA',
  start_url: './#connect',
  scope: './',
  display: 'standalone',
  background_color: '#0d0d1a',
  theme_color: '#1a1a2e',
  icons: [{ src: 'icon-192.svg', sizes: '192x192', type: 'image/svg+xml', purpose: 'any maskable' }],
});

describe('rewriteManifest — custom name (#131)', () => {
  it('returns default name when no customName provided', () => {
    const result = JSON.parse(rewriteManifest(Buffer.from(DEFAULT_MANIFEST)).toString());
    expect(result.name).toBe('MobiSSH');
    expect(result.short_name).toBe('MobiSSH');
  });

  it('returns default name when customName is empty string', () => {
    const result = JSON.parse(rewriteManifest(Buffer.from(DEFAULT_MANIFEST), '').toString());
    expect(result.name).toBe('MobiSSH');
    expect(result.short_name).toBe('MobiSSH');
  });

  it('overrides name and short_name when customName is provided', () => {
    const result = JSON.parse(rewriteManifest(Buffer.from(DEFAULT_MANIFEST), 'fd-mobissh').toString());
    expect(result.name).toBe('fd-mobissh');
    expect(result.short_name).toBe('fd-mobissh');
  });

  it('still sets stable id, start_url, and scope with custom name', () => {
    const result = JSON.parse(rewriteManifest(Buffer.from(DEFAULT_MANIFEST), 'Work SSH').toString());
    expect(result.id).toBe('mobissh');
    expect(result.start_url).toBe('./#connect');
    expect(result.scope).toBe('./');
  });

  it('preserves other manifest fields when custom name is provided', () => {
    const result = JSON.parse(rewriteManifest(Buffer.from(DEFAULT_MANIFEST), 'My SSH').toString());
    expect(result.display).toBe('standalone');
    expect(result.icons).toHaveLength(1);
    expect(result.description).toBe('Mobile-first SSH PWA');
  });
});
