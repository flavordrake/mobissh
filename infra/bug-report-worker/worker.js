// MobiSSH public bug-report receiver — Cloudflare Worker (#966).
//
// The public Play build can't reach the tailnet endpoint, so the in-app
// "Send" (after the #967 Review & Send consent gate) POSTs the report JSON here.
// This Worker validates a light shared key, size-caps the body, stores the
// report in R2 (YOU own retention/deletion — matches the privacy policy), and
// optionally fires an ntfy ping. It is the SOLE recipient; no third-party
// analytics or trackers are involved.
//
// Bindings / vars (see wrangler.toml):
//   - R2 bucket binding:  REPORTS
//   - secret:             FEEDBACK_KEY   (must equal the app's X-MobiSSH-Key)
//   - var (optional):     NTFY_URL       (full ntfy topic URL to ping on receipt)
//   - secret (optional):  NTFY_TOKEN     (Bearer for NTFY_URL, if the topic is auth'd)
//
// Contract: POST application/json, header X-MobiSSH-Key: <FEEDBACK_KEY>.
// Body is the payload from buildFeedbackPayload (comment/version/screenshot/
// frames/…). The user already chose (via the Review sheet) what's included.

const MAX_BYTES = 25 * 1024 * 1024; // 25 MB — a 50-frame burst + traces fits.

export default {
  async fetch(request, env) {
    if (request.method !== 'POST') {
      return json({ error: 'POST only' }, 405);
    }
    // Light gate so it's not a fully-open drop box. Not strong auth — pairs with
    // the size cap; R2 write is the only side effect.
    if (!env.FEEDBACK_KEY || request.headers.get('X-MobiSSH-Key') !== env.FEEDBACK_KEY) {
      return json({ error: 'forbidden' }, 403);
    }
    const len = Number(request.headers.get('Content-Length') || '0');
    if (len > MAX_BYTES) {
      return json({ error: 'payload too large' }, 413);
    }

    const body = await request.text();
    if (body.length > MAX_BYTES) {
      return json({ error: 'payload too large' }, 413);
    }
    // Validate it's JSON; keep the raw text for storage (lossless).
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
        hasScreenshot: String(Boolean(parsed.screenshot)),
        frameCount: String(Array.isArray(parsed.frames) ? parsed.frames.length : 0),
      },
    });

    // Best-effort notify — never blocks the 200.
    if (env.NTFY_URL) {
      try {
        const title = String(parsed.title || 'MobiSSH bug report').slice(0, 200);
        await fetch(env.NTFY_URL, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            ...(env.NTFY_TOKEN ? { Authorization: `Bearer ${env.NTFY_TOKEN}` } : {}),
          },
          body: JSON.stringify({ title, message: `Stored ${key}`, tags: ['bug'] }),
        });
      } catch {
        // notify is best-effort
      }
    }

    return json({ ok: true, id });
  },
};

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}
