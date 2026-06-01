// native-time.js — renders the build's RELATIVE age ("3 minutes ago") next to
// the absolute build time on the APK install page (native.html).
//
// Loaded as a same-origin <script src> (the page's CSP is `script-src 'self'`,
// which permits external same-origin scripts but blocks inline JS — hence a
// file rather than an inline block). It reads the build epoch from the
// #build-rel span's data-epoch (emitted by gen-apk-install-page.sh) and fills
// in a live "(… ago)" string. Re-runs on pageshow so a back/forward restore
// re-computes. Absolute time is always shown by the server-rendered HTML, so a
// failure here degrades to "absolute time only", never a blank.

(function () {
  function ago(seconds) {
    if (seconds < 0) return 'just now';
    if (seconds < 45) return 'just now';
    if (seconds < 90) return '1 minute ago';
    var mins = Math.round(seconds / 60);
    if (mins < 60) return mins + ' minutes ago';
    var hours = Math.round(mins / 60);
    if (hours < 24) return hours + (hours === 1 ? ' hour ago' : ' hours ago');
    var days = Math.round(hours / 24);
    if (days < 30) return days + (days === 1 ? ' day ago' : ' days ago');
    var months = Math.round(days / 30);
    return months + (months === 1 ? ' month ago' : ' months ago');
  }

  function render() {
    var el = document.getElementById('build-rel');
    if (!el) return;
    var epoch = parseInt(el.getAttribute('data-epoch'), 10);
    if (!epoch || isNaN(epoch)) return; // no epoch → leave absolute-only
    var nowSec = Date.now() / 1000;
    var age = nowSec - epoch;
    el.textContent = '(' + ago(age) + ')';
    // Tint amber once the build is more than a day old — a quick "this might be
    // stale, refresh" signal.
    if (age > 86400) el.className = 'rel stale';
    else el.className = 'rel';
  }

  render();
  window.addEventListener('pageshow', render);
})();
