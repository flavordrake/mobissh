/**
 * MobiSSH PWA — Service Worker
 *
 * Caches the app shell for offline/installable PWA.
 * The WebSocket connection itself is always live (no caching).
 */

const CACHE_NAME = 'mobissh-d33fe98a';

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
  './modules/ui.js',
  './modules/ime.js',
  './modules/terminal.js',
  './app.css',
  './recovery.js',
  './ws-keepalive-worker.js',
  './manifest.json',
  './icon-192.svg',
  './icon-512.svg',
  './vendor/xterm.min.js',
  './vendor/xterm.min.css',
  './vendor/xterm-addon-fit.min.js',
];

// Install: cache the app shell
self.addEventListener('install', (event) => {
  console.log(`[sw] installing ${CACHE_NAME}`);
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => {
      return cache.addAll(SHELL_FILES).catch((err) => {
        // Non-fatal: offline caching is best-effort
        console.warn('[sw] cache addAll failed:', err);
      });
    })
  );
  self.skipWaiting();
});

// Activate: clean up old caches
self.addEventListener('activate', (event) => {
  console.log(`[sw] activating ${CACHE_NAME}`);
  event.waitUntil(
    caches.keys().then((keys) => {
      const stale = keys.filter((key) => key !== CACHE_NAME);
      if (stale.length > 0) console.log(`[sw] purging stale caches: ${stale.join(', ')}`);
      return Promise.all(stale.map((key) => caches.delete(key)));
    })
  );
  self.clients.claim();
});

// Notification click: focus or open the app when tapping a notification.
// Uses origin + pathname prefix matching so hash routes (#connect, #terminal)
// and query params don't prevent focusing the existing PWA window (#219).
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((clients) => {
      const scopeUrl = new URL(self.registration.scope);
      // Focus existing window if available
      for (const client of clients) {
        try {
          const clientUrl = new URL(client.url);
          const sameApp =
            clientUrl.origin === scopeUrl.origin &&
            clientUrl.pathname.startsWith(scopeUrl.pathname);
          if (sameApp && 'focus' in client) {
            return client.focus();
          }
        } catch (_) {
          // Malformed URL — skip this client
        }
      }
      // Otherwise open a new window
      return self.clients.openWindow(self.registration.scope);
    })
  );
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
          if (cached) {
            console.log(`[sw] serving from cache (offline): ${event.request.url}`);
            return cached;
          }
          if (event.request.mode === 'navigate') {
            console.log('[sw] serving cached index.html (offline fallback)');
            return caches.match('./index.html');
          }
        });
      })
  );
});
