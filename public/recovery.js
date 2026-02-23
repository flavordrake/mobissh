/**
 * MobiSSH PWA — Recovery watchdog + emergency escape hatch
 *
 * Loaded before app.js. Three responsibilities:
 *
 *   1. ?reset=1 handler — emergency cache clear + reload.
 *      The SW also handles this (sw.js), giving two independent paths:
 *        a. SW working: SW intercepts navigate, clears caches, redirects.
 *        b. SW broken: server serves fresh index.html, this script runs.
 *
 *   2. Boot watchdog — if the app hasn't signalled readiness within
 *      BOOT_TIMEOUT_MS, show the inline recovery overlay (index.html).
 *      app.js calls window.__appReady() after DOMContentLoaded init.
 *
 *   3. Long-press escape hatch — long-press (1.5s) on the Settings tab
 *      clears SW caches and reloads. Works even when the app's JS event
 *      handlers fail to attach.
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
      location.replace(location.pathname);
    }());
    return;
  }

  // Boot watchdog — only trust the __appReady signal, not DOM heuristics.
  // Static HTML renders even when JS fails, so checking tabBar height is wrong.
  var BOOT_TIMEOUT_MS = 8000;
  var booted = false;

  window.__appReady = function () {
    booted = true;
  };

  setTimeout(function () {
    if (booted) return;
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

  // Long-press escape hatch on Settings tab (1.5s hold clears SW + caches)
  document.addEventListener('DOMContentLoaded', function () {
    var settingsBtn = document.querySelector('[data-panel="settings"]');
    if (!settingsBtn) return;
    var timer = null;

    function clearTimer() {
      if (timer) { clearTimeout(timer); timer = null; }
    }

    function doReset() {
      timer = null;
      if (!confirm('Clear service workers and caches?\n(Profiles and settings are preserved)')) return;
      Promise.resolve()
        .then(function () { return navigator.serviceWorker.getRegistrations(); })
        .then(function (regs) { return Promise.all(regs.map(function (r) { return r.unregister(); })); })
        .catch(function () {})
        .then(function () { return caches.keys(); })
        .then(function (keys) { return Promise.all(keys.map(function (k) { return caches.delete(k); })); })
        .catch(function () {})
        .then(function () { location.reload(); });
    }

    settingsBtn.addEventListener('touchstart', function () {
      timer = setTimeout(doReset, 1500);
    }, { passive: true });
    settingsBtn.addEventListener('touchend', clearTimer);
    settingsBtn.addEventListener('touchmove', clearTimer);
  });
}());
