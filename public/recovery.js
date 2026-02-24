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

  var RESET_COUNT_KEY = 'mobissh_reset_count';
  var RESET_TS_KEY = 'mobissh_reset_ts';
  var MAX_RESETS = 2;         // stop looping after this many resets in the time window
  var RESET_WINDOW_MS = 30000; // 30 seconds

  // ?reset=1 handler
  if (location.search.indexOf('reset=1') !== -1) {
    (async function () {
      // Track reset count to detect loops
      var now = Date.now();
      var lastTs = parseInt(sessionStorage.getItem(RESET_TS_KEY)) || 0;
      var count = parseInt(sessionStorage.getItem(RESET_COUNT_KEY)) || 0;
      if (now - lastTs > RESET_WINDOW_MS) count = 0;
      count++;
      sessionStorage.setItem(RESET_COUNT_KEY, count);
      sessionStorage.setItem(RESET_TS_KEY, now);

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
  var bootError = null;

  window.__appReady = function () {
    booted = true;
    // Clear reset counter on successful boot
    try {
      sessionStorage.removeItem(RESET_COUNT_KEY);
      sessionStorage.removeItem(RESET_TS_KEY);
    } catch (_) {}
  };

  // Called by app.js if the DOMContentLoaded handler throws
  window.__appBootError = function (err) {
    bootError = err;
  };

  function showOverlay() {
    var overlay = document.getElementById('recovery-overlay');
    if (!overlay) return;
    overlay.style.display = 'flex';

    var resetCount = parseInt(sessionStorage.getItem(RESET_COUNT_KEY)) || 0;

    // Show diagnostic info
    var diagLines = [];
    if (bootError) {
      diagLines.push('Error: ' + bootError.message);
      if (bootError.stack) {
        var firstFrame = bootError.stack.split('\n').slice(0, 3).join('\n');
        diagLines.push(firstFrame);
      }
    }
    if (typeof Terminal === 'undefined') diagLines.push('xterm.js failed to load (CDN blocked?)');
    if (typeof FitAddon === 'undefined') diagLines.push('xterm-addon-fit failed to load');

    // Inject diagnostics below the existing overlay content
    if (diagLines.length > 0) {
      var pre = document.createElement('pre');
      pre.style.cssText = 'color:#ff8800;font-size:11px;max-width:320px;text-align:left;' +
        'margin-top:16px;white-space:pre-wrap;word-break:break-all;line-height:1.4';
      pre.textContent = diagLines.join('\n');
      overlay.appendChild(pre);
    }

    // If we've reset too many times, change the button to prevent further looping
    if (resetCount >= MAX_RESETS) {
      var btn = document.getElementById('recovery-reset-btn');
      if (btn) {
        btn.textContent = 'Reset (loop detected)';
        btn.style.background = '#ff4444';
      }
      var hint = document.createElement('p');
      hint.style.cssText = 'color:#ff8800;font-size:13px;margin-top:12px;max-width:320px;line-height:1.5';
      hint.textContent = 'Multiple resets have not fixed the issue. Try: ' +
        '(1) check network/VPN, (2) open in Chrome browser instead of installed app, ' +
        '(3) uninstall and reinstall the app.';
      overlay.appendChild(hint);
    }
  }

  setTimeout(function () {
    if (booted && !bootError) return;
    showOverlay();
  }, BOOT_TIMEOUT_MS);

  // If app.js reported an error, show overlay immediately (don't wait 8s)
  window.__appBootError = function (err) {
    bootError = err;
    showOverlay();
  };

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
