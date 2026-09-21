/**
 * test/infra/manifest-name.test.js
 *
 * rewriteManifest() in server/manifest.js — dynamic manifest name rewriting (#131).
 *
 * Relocated from src/modules/__tests__/manifest-name.test.ts when the PWA was
 * retired (#1205). Runner is node:test so it needs no node_modules and runs
 * inside agent worktrees; see scripts/test-infra.sh.
 */

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

const { rewriteManifest } = require(path.join(__dirname, '../../server/manifest.js'));

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

function rewrite(customName) {
  return JSON.parse(rewriteManifest(Buffer.from(DEFAULT_MANIFEST), customName).toString());
}

describe('rewriteManifest — custom name (#131)', () => {
  it('returns default name when no customName provided', () => {
    const result = rewrite();
    assert.equal(result.name, 'MobiSSH');
    assert.equal(result.short_name, 'MobiSSH');
  });

  it('returns default name when customName is empty string', () => {
    const result = rewrite('');
    assert.equal(result.name, 'MobiSSH');
    assert.equal(result.short_name, 'MobiSSH');
  });

  it('overrides name and short_name when customName is provided', () => {
    const result = rewrite('fd-mobissh');
    assert.equal(result.name, 'fd-mobissh');
    assert.equal(result.short_name, 'fd-mobissh');
  });

  it('still sets stable id, start_url, and scope with custom name', () => {
    const result = rewrite('Work SSH');
    assert.equal(result.id, 'mobissh');
    assert.equal(result.start_url, './#connect');
    assert.equal(result.scope, './');
  });

  it('preserves other manifest fields when custom name is provided', () => {
    const result = rewrite('My SSH');
    assert.equal(result.display, 'standalone');
    assert.equal(result.icons.length, 1);
    assert.equal(result.description, 'Mobile-first SSH PWA');
  });
});
