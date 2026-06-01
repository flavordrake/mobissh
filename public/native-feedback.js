// native-feedback.js — version-scoped feedback form on the APK install page
// (native.html, #609).
//
// Posts to the EXISTING /api/bug-report endpoint (server/index.js) — which
// already accepts { screenshot (base64 data URL), title, version } and saves to
// test-results/uploads/, the dir the orchestrator watches. The point here is
// the `version` field: it's pre-filled to THIS build's stamp + commit hash (via
// the form's data-version), so every report is tightly tied to exactly what was
// shipping when the owner hit it — letting feedback flow async while the live
// conversation stays for hard design topics.
//
// Same-origin script (CSP: script-src 'self' permits external same-origin JS,
// blocks inline; connect-src 'self' permits the POST). No deps.

(function () {
  var form = document.getElementById('fb-form');
  if (!form) return;

  var textEl = document.getElementById('fb-text');
  var imgEl = document.getElementById('fb-img');
  var imgNameEl = document.getElementById('fb-imgname');
  var sendEl = document.getElementById('fb-send');
  var statusEl = document.getElementById('fb-status');

  var version = form.getAttribute('data-version') || 'unknown';

  // Hold the selected image as a base64 data URL (what /api/bug-report wants).
  var screenshot = null;

  imgEl.addEventListener('change', function () {
    var file = imgEl.files && imgEl.files[0];
    if (!file) {
      screenshot = null;
      imgNameEl.textContent = '';
      return;
    }
    imgNameEl.textContent = file.name;
    var reader = new FileReader();
    reader.onload = function () {
      screenshot = reader.result; // data:image/...;base64,...
    };
    reader.onerror = function () {
      screenshot = null;
      setStatus('Could not read that image — try another.', 'err');
    };
    reader.readAsDataURL(file);
  });

  function setStatus(msg, cls) {
    statusEl.textContent = msg;
    statusEl.className = 'status' + (cls ? ' ' + cls : '');
  }

  form.addEventListener('submit', function (e) {
    e.preventDefault();
    var text = (textEl.value || '').trim();
    if (!text && !screenshot) {
      setStatus('Add a note or a screenshot first.', 'err');
      return;
    }
    sendEl.disabled = true;
    setStatus('Sending…', '');

    // First line of the note becomes the title (so uploads/*.json reads well);
    // full note + version go in the body fields the endpoint already stores.
    var firstLine = text.split('\n')[0].slice(0, 80);
    var payload = {
      title: firstLine ? '[' + version + '] ' + firstLine : 'Feedback ' + version,
      logs: text,
      version: version,
      url: location.href,
      userAgent: navigator.userAgent,
    };
    if (screenshot) payload.screenshot = screenshot;

    fetch('./api/bug-report', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    })
      .then(function (r) {
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return r.json();
      })
      .then(function () {
        setStatus('Sent — tagged to this build. Thanks!', 'ok');
        textEl.value = '';
        imgEl.value = '';
        imgNameEl.textContent = '';
        screenshot = null;
        sendEl.disabled = false;
      })
      .catch(function (err) {
        setStatus('Send failed (' + err.message + '). Try again.', 'err');
        sendEl.disabled = false;
      });
  });
})();
