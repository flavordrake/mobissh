/**
 * MobiSSH PWA — Service Worker
 *
 * Caches the app shell for offline/installable PWA.
 * The WebSocket connection itself is always live (no caching).
 */

const CACHE_NAME = 'mobissh-v13';

// Files to cache for offline shell.
// Relative paths so they resolve correctly when served at a subpath (e.g. /ssh/).
const SHELL_FILES = [
  './',
  './index.html',
  './app.js',
  './modules/constants.js',
  './modules/state.js',
  './modules/recording.js',
  './modules/vault.js',
  './modules/profiles.js',
  './modules/settings.js',
  './modules/connection.js',
  './app.css',
  './recovery.js',
  './manifest.json',
  './icon-192.svg',
  './icon-512.svg',
  './vendor/xterm.min.js',
  './vendor/xterm.min.css',
  './vendor/xterm-addon-fit.min.js',
];

// Install: cache the app shell
self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => {
      return cache.addAll(SHELL_FILES).catch((err) => {
        // Non-fatal: offline caching is best-effort
        console.warn('[sw] Cache addAll failed:', err);
      });
    })
  );
  self.skipWaiting();
});

// Activate: clean up old caches
self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(
        keys
          .filter((key) => key !== CACHE_NAME)
          .map((key) => caches.delete(key))
      )
    )
  );
  self.clients.claim();
});

// Fetch: network-first — always try network, cache is offline fallback only.
// This ensures updated app.js/app.css are always served fresh.
self.addEventListener('fetch', (event) => {
  if (event.request.method !== 'GET') return;
  if (event.request.url.startsWith('ws://') || event.request.url.startsWith('wss://')) return;

  // Emergency recovery: ?reset=1 clears all SW caches and redirects to the
  // app base URL. Handled here so recovery works even when the page itself
  // can't render (e.g. corrupt cached index.html). The script in recovery.js
  // provides a second fallback for when the SW itself is broken.
  const url = new URL(event.request.url);
  if (event.request.mode === 'navigate' && url.searchParams.get('reset') === '1') {
    event.respondWith(
      caches.keys()
        .then((keys) => Promise.all(keys.map((k) => caches.delete(k))))
        .then(() => Response.redirect(new URL('./', event.request.url).href, 302))
    );
    return;
  }

  event.respondWith(
    fetch(event.request)
      .then((response) => {
        // Update cache with fresh response
        if (response.ok) {
          const clone = response.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(event.request, clone));
        }
        return response;
      })
      .catch(() => {
        // Network failed — serve from cache (offline)
        return caches.match(event.request).then((cached) => {
          if (cached) return cached;
          if (event.request.mode === 'navigate') return caches.match('./index.html');
        });
      })
  );
});
