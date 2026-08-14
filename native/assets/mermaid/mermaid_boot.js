// Boot script for the offline mermaid render host (mermaid_host.html).
//
// Externalized from an inline <script> block so the host can enforce a strict
// Content-Security-Policy with `script-src 'self'` (no 'unsafe-inline'). The CSP
// blocks ALL network egress (connect-src 'none', img-src data:, default-src
// 'none') so untrusted diagram data can never beacon out (#1107 sibling). This
// file is a bundled Flutter asset loaded via <script src>, so 'self' covers it.

function post(payload) {
  try {
    if (window.MermaidChannel && window.MermaidChannel.postMessage) {
      window.MermaidChannel.postMessage(JSON.stringify(payload));
    }
  } catch (e) {
    /* channel not attached (e.g. preview) — ignore */
  }
}

var mermaidReady = false;
try {
  if (window.mermaid) {
    window.mermaid.initialize({ startOnLoad: false, securityLevel: 'strict' });
    mermaidReady = true;
  }
} catch (e) {
  post({ type: 'error', message: 'mermaid init failed: ' + e });
}

function reportSize() {
  var el = document.getElementById('diagram');
  var h = Math.ceil(el.getBoundingClientRect().height);
  if (h > 0) post({ type: 'size', height: h });
}

// Called from Dart with the raw fenced-block source.
window.renderMermaid = function (source) {
  var target = document.getElementById('diagram');
  if (!mermaidReady || !window.mermaid) {
    post({ type: 'error', message: 'mermaid unavailable' });
    return;
  }
  try {
    window.mermaid
      .render('mermaidGraph', source)
      .then(function (result) {
        target.innerHTML = result.svg;
        reportSize();
        // Re-measure after layout settles (fonts/labels).
        setTimeout(reportSize, 60);
      })
      .catch(function (err) {
        post({ type: 'error', message: String(err && err.message ? err.message : err) });
      });
  } catch (err) {
    post({ type: 'error', message: String(err && err.message ? err.message : err) });
  }
};
