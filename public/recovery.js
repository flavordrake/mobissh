/**
 * MobiSSH PWA — Recovery watchdog
 *
 * Loaded before app.js. Two responsibilities:
 *
 *   1. ?reset=1 handler — emergency cache clear + reload.
 *      The SW also handles this (sw.js), giving us two independent paths:
 *        a. SW working: SW intercepts navigate, clears caches, redirects.
 *        b. SW broken: server serves fresh index.html, this script runs.
 *
 *   2. Boot watchdog — if the app hasn't signalled readiness within
 *      BOOT_TIMEOUT_MS, show the inline recovery overlay (index.html).
 *      app.js calls window.__appReady() after DOMContentLoaded init.
 *
 *   NOTE: ?reset=1 and /clear are development aids. They should be stripped
 *   or gated before production release.
 */

(function () {
  'use strict';

  // ?reset=1 handler
  if (location.search.indexOf('reset=1') !== -1) {
    (async function () {
      try {
        var regs = await navigator.serviceWorker.getRegistrations();
        await Promise.all(regs.map(function (r) { return r.unregister(); }));
      } catch (_) {}
      try {
        var keys = await caches.keys();
        await Promise.all(keys.map(function (k) { return caches.delete(k); }));
      } catch (_) {}
      // Navigate to the bare base path — strip query string.
      location.replace(location.pathname);
    }());
    return;
  }

  // Boot watchdog
  var BOOT_TIMEOUT_MS = 8000;
  var booted = false;

  // app.js calls this once DOMContentLoaded initialization is complete.
  window.__appReady = function () {
    booted = true;
  };

  setTimeout(function () {
    if (booted) return;
    // Secondary check: if #tabBar rendered, the app is alive.
    var tabBar = document.getElementById('tabBar');
    if (tabBar && tabBar.offsetHeight > 0) return;
    // App appears broken — reveal the recovery overlay.
    var overlay = document.getElementById('recovery-overlay');
    if (overlay) overlay.style.display = 'flex';
  }, BOOT_TIMEOUT_MS);

  // Recovery button
  document.addEventListener('DOMContentLoaded', function () {
    var btn = document.getElementById('recovery-reset-btn');
    if (btn) {
      btn.addEventListener('click', function () {
        location.href = location.pathname + '?reset=1';
      });
    }
  });
}());
