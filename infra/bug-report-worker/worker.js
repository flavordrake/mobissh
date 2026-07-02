// MobiSSH bug-report Worker (#966) — ingest + viewer + privacy page.
//
// Routes:
//   POST /                → ingest a report (writer key: X-MobiSSH-Key == FEEDBACK_KEY),
//                           size-capped, stored in R2, optional ntfy ping.
//   GET  /                → viewer: list reports (Basic auth, password = VIEW_KEY).
//   GET  /r/<objectKey>   → viewer: render one report (Basic auth).
//   GET  /privacy         → public HTML privacy policy (no auth).
//
// SECURITY: ingest is PUBLIC, so report fields are attacker-controlled. The
// viewer HTML-escapes every rendered field and only emits data:image/ URLs, so
// a malicious comment can't XSS the owner's browser (which holds VIEW_KEY).
//
// Bindings (REST metadata): R2 bucket REPORTS; secrets FEEDBACK_KEY, VIEW_KEY;
// optional vars NTFY_URL / secret NTFY_TOKEN.

const MAX_BYTES = 25 * 1024 * 1024; // 25 MB

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;

    if (request.method === 'POST') return ingest(request, env);

    if (request.method === 'GET') {
      if (path === '/privacy') return html(PRIVACY_HTML);
      if (path === '/' || path === '/r' || path.startsWith('/r/')) {
        if (!viewerOk(request, env)) return needAuth();
        if (path.startsWith('/r/')) {
          return viewReport(decodeURIComponent(path.slice(3)), env);
        }
        return listReports(env);
      }
    }
    return new Response('Not found', { status: 404 });
  },
};

// ── ingest ───────────────────────────────────────────────────────────────
async function ingest(request, env) {
  if (!env.FEEDBACK_KEY || request.headers.get('X-MobiSSH-Key') !== env.FEEDBACK_KEY) {
    return json({ error: 'forbidden' }, 403);
  }
  const len = Number(request.headers.get('Content-Length') || '0');
  if (len > MAX_BYTES) return json({ error: 'payload too large' }, 413);

  const body = await request.text();
  if (body.length > MAX_BYTES) return json({ error: 'payload too large' }, 413);

  let parsed;
  try {
    parsed = JSON.parse(body);
  } catch {
    return json({ error: 'invalid JSON' }, 400);
  }

  const id = crypto.randomUUID();
  const now = new Date();
  const key = `reports/${now.toISOString().slice(0, 10)}/${now.toISOString().replace(/[:.]/g, '-')}-${id}.json`;

  await env.REPORTS.put(key, body, {
    httpMetadata: { contentType: 'application/json' },
    customMetadata: {
      version: String(parsed.version || ''),
      source: String(parsed.source || ''),
      title: String(parsed.title || '').slice(0, 300),
      hasScreenshot: String(Boolean(parsed.screenshot)),
      frameCount: String(Array.isArray(parsed.frames) ? parsed.frames.length : 0),
    },
  });

  if (env.NTFY_URL) {
    try {
      await fetch(env.NTFY_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          ...(env.NTFY_TOKEN ? { Authorization: `Bearer ${env.NTFY_TOKEN}` } : {}),
        },
        body: JSON.stringify({
          title: String(parsed.title || 'MobiSSH bug report').slice(0, 200),
          message: `Stored ${key}`,
          tags: ['bug'],
        }),
      });
    } catch {
      // notify is best-effort
    }
  }

  return json({ ok: true, id });
}

// ── viewer ───────────────────────────────────────────────────────────────
function viewerOk(request, env) {
  if (!env.VIEW_KEY) return false;
  const h = request.headers.get('Authorization') || '';
  if (!h.startsWith('Basic ')) return false;
  let decoded = '';
  try {
    decoded = atob(h.slice(6));
  } catch {
    return false;
  }
  const pass = decoded.slice(decoded.indexOf(':') + 1);
  return pass === env.VIEW_KEY;
}

function needAuth() {
  return new Response('Auth required', {
    status: 401,
    headers: { 'WWW-Authenticate': 'Basic realm="mobissh reports"' },
  });
}

async function listReports(env) {
  const listed = await env.REPORTS.list({ prefix: 'reports/', limit: 1000 });
  const rows = listed.objects
    .sort((a, b) => (a.uploaded < b.uploaded ? 1 : -1))
    .map((o) => {
      const m = o.customMetadata || {};
      return `<tr>
        <td><a href="/r/${esc(encodeURIComponent(o.key))}">${esc(o.uploaded)}</a></td>
        <td>${esc(m.version || '')}</td>
        <td>${esc((m.title || '').slice(0, 80))}</td>
        <td>${m.hasScreenshot === 'true' ? '📷' : ''}${Number(m.frameCount) ? ' 🎞️' + esc(m.frameCount) : ''}</td>
      </tr>`;
    })
    .join('');
  return html(`${HEAD}<h1>Bug reports (${listed.objects.length})</h1>
    <table><tr><th>received</th><th>version</th><th>title</th><th>media</th></tr>${rows}</table>`);
}

async function viewReport(key, env) {
  const obj = await env.REPORTS.get(key);
  if (!obj) return new Response('Not found', { status: 404 });
  let r;
  try {
    r = JSON.parse(await obj.text());
  } catch {
    return new Response('corrupt report', { status: 500 });
  }
  const img = (d) =>
    typeof d === 'string' && d.startsWith('data:image/')
      ? `<img loading="lazy" src="${esc(d)}">`
      : '';
  const frames = Array.isArray(r.frames)
    ? `<h3>Frames (${r.frames.length})</h3><div class="strip">${r.frames.map(img).join('')}</div>`
    : '';
  const traceBlock = (label, val) =>
    val == null
      ? ''
      : `<details><summary>${esc(label)}</summary><pre>${esc(
          typeof val === 'string' ? val : JSON.stringify(val, null, 2)
        )}</pre></details>`;
  return html(`${HEAD}<p><a href="/">&larr; all reports</a></p>
    <h1>${esc(r.title || 'report')}</h1>
    <p><b>version:</b> ${esc(r.version || '')} · <b>source:</b> ${esc(r.source || '')}</p>
    <h3>Comment</h3><pre>${esc(r.comment || '')}</pre>
    ${r.screenshot ? '<h3>Screenshot</h3>' + img(r.screenshot) : ''}
    ${frames}
    ${traceBlock('connectLog', r.connectLog)}
    ${traceBlock('gestureLog', r.gestureLog)}
    ${traceBlock('lifecycleLog', r.lifecycleLog)}
    ${traceBlock('byteTrace', r.byteTrace)}
    ${traceBlock('scrollTrace', r.scrollTrace)}
    ${traceBlock('sentSgrTrace', r.sentSgrTrace)}
    ${traceBlock('grid', r.grid)}`);
}

// ── helpers ──────────────────────────────────────────────────────────────
function esc(s) {
  return String(s == null ? '' : s)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

function html(s, status = 200) {
  return new Response(s, {
    status,
    headers: { 'Content-Type': 'text/html; charset=utf-8' },
  });
}

const HEAD = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<style>body{font:15px system-ui,sans-serif;margin:1rem;max-width:900px}
table{border-collapse:collapse;width:100%}td,th{border:1px solid #ccc;padding:4px 8px;text-align:left;font-size:13px}
pre{white-space:pre-wrap;word-break:break-word;background:#f6f6f6;padding:8px;border-radius:6px}
img{max-width:100%;border:1px solid #ddd;border-radius:6px;margin:4px 0}
.strip{display:flex;gap:6px;overflow-x:auto}.strip img{height:220px;max-width:none}
details{margin:6px 0}summary{cursor:pointer}a{color:#06c}</style>`;

const PRIVACY_HTML = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>MobiSSH Privacy Policy</title>
<style>body{font:16px/1.5 system-ui,sans-serif;margin:2rem auto;max-width:760px;padding:0 1rem;color:#222}
h1{font-size:1.6rem}h2{font-size:1.15rem;margin-top:1.6rem}code{background:#f0f0f0;padding:1px 4px;border-radius:4px}</style>
<h1>MobiSSH — Privacy Policy</h1>
<p><b>Effective date:</b> 2026-07-02 · <b>App:</b> MobiSSH (<code>com.flavordrake.mobissh</code>) · <b>Contact:</b> flavordrake@gmail.com</p>
<p><b>Your data is yours.</b> MobiSSH is an SSH/SFTP client. Your credentials and your terminal
sessions stay on your device and flow directly between your device and the servers you connect to.
The developer's systems are not in that path and never receive your session content — except the one
diagnostic bundle you explicitly choose to send. No ads, no third-party analytics or trackers, no sale of your data.</p>
<h2>1. Data that stays on your device</h2>
<p>Saved SSH passwords, private keys, and passphrases are stored encrypted on the device (AES-GCM, key
in the platform's hardware-backed store) and are sent only to the SSH server you connect to. Connection
profiles and app settings are stored locally. None of this is sent to the developer.</p>
<h2>2. Data that flows only between you and your servers</h2>
<p>MobiSSH connects directly from your device to the servers you choose. Commands, terminal output, and
files you browse/transfer travel over that direct, encrypted SSH connection. The developer operates no
proxy or relay in this path and cannot see this content.</p>
<h2>3. Bug reports you choose to send</h2>
<p>Only when you tap <b>Send bug report</b> does the app upload a diagnostic bundle. Before sending, a
<b>Review &amp; Send</b> screen lets you preview the screenshot (or every frame of a recording) and
<b>exclude the screen images and/or the diagnostic traces</b>; nothing is sent until you confirm. A bundle
may include a screenshot/frames, recent terminal I/O and diagnostic logs, your device model, OS version,
and app version. Because images capture your screen, they may contain session content — which is why you
review them. An automated pass also redacts secret-looking text from logs (best-effort, not a guarantee).</p>
<p><b>Purpose:</b> only to diagnose the reported bug. <b>Recipient:</b> the developer only; not shared or
sold. <b>Retention:</b> kept only as long as needed and no more than <b>30 days</b>, then deleted.
<b>Deletion:</b> email flavordrake@gmail.com to have a report you sent deleted.</p>
<h2>4. Permissions</h2>
<p>Foreground service + notifications (keep your SSH session alive in the background and show its status);
optional battery-optimization exemption (prevent the OS freezing the connection while the screen is off);
storage (write files you download over SFTP to Downloads); internet (connect to your servers).</p>
<h2>5. What we do not do</h2>
<p>No advertising or ad IDs. No third-party analytics, tracking, or profiling. No selling or sharing of
your data. No background collection of your session content, credentials, or usage.</p>
<h2>6. Children</h2><p>MobiSSH is a developer tool, not directed to children under 13.</p>
<h2>7. Changes</h2><p>Updates are posted at this URL with a new effective date.</p>
<h2>8. Contact</h2><p>Questions or deletion requests: <b>flavordrake@gmail.com</b></p>`;
