'use strict';

/**
 * Dynamic manifest.json rewriting.
 *
 * Rewrites manifest.json fields so the PWA installs correctly under any
 * reverse-proxy subpath (#83), and supports custom name/short_name via a
 * query parameter for multi-installation support (#131).
 *
 * - id: stable "mobissh" identity prevents collision with other apps
 * - start_url / scope: "./" is relative to the manifest URL, so Chrome
 *   resolves them to the correct subpath regardless of where the app is hosted
 * - name / short_name: overridden when customName is provided (#131)
 *   Allows multiple installs with distinct home-screen titles.
 *
 * @param {Buffer} buf         - raw manifest.json file contents
 * @param {string} [customName] - optional custom name/short_name override
 * @returns {Buffer} rewritten manifest as a Buffer
 */
function rewriteManifest(buf, customName) {
  const manifest = JSON.parse(buf.toString());
  manifest.id = 'mobissh';
  manifest.start_url = './#connect';
  manifest.scope = './';
  if (customName) {
    manifest.name = customName;
    manifest.short_name = customName;
  }
  return Buffer.from(JSON.stringify(manifest));
}

module.exports = { rewriteManifest };
