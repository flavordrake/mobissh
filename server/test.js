'use strict';

/**
 * server/test.js — unit tests for server helper functions
 *
 * Run with: npm test  (from the server/ directory)
 */

const { test } = require('node:test');
const assert = require('node:assert/strict');

const { rewriteManifest } = require('./index.js');

test('rewriteManifest: sets id="mobissh"', () => {
  const input = Buffer.from(JSON.stringify({ name: 'MobiSSH', start_url: '/' }));
  const result = JSON.parse(rewriteManifest(input));
  assert.equal(result.id, 'mobissh');
});

test('rewriteManifest: sets start_url="./"', () => {
  const input = Buffer.from(JSON.stringify({ start_url: '/' }));
  const result = JSON.parse(rewriteManifest(input));
  assert.equal(result.start_url, './');
});

test('rewriteManifest: sets scope="./"', () => {
  const input = Buffer.from(JSON.stringify({ name: 'MobiSSH' }));
  const result = JSON.parse(rewriteManifest(input));
  assert.equal(result.scope, './');
});

test('rewriteManifest: preserves other manifest fields', () => {
  const input = Buffer.from(JSON.stringify({
    name: 'MobiSSH',
    theme_color: '#1a1a2e',
    icons: [{ src: 'icon-192.svg', sizes: '192x192' }],
  }));
  const result = JSON.parse(rewriteManifest(input));
  assert.equal(result.name, 'MobiSSH');
  assert.equal(result.theme_color, '#1a1a2e');
  assert.deepEqual(result.icons, [{ src: 'icon-192.svg', sizes: '192x192' }]);
});

test('rewriteManifest: overwrites existing id', () => {
  const input = Buffer.from(JSON.stringify({ id: 'old-id', name: 'MobiSSH' }));
  const result = JSON.parse(rewriteManifest(input));
  assert.equal(result.id, 'mobissh');
});
