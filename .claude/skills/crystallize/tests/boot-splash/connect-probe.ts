/**
 * modules/connect-probe.ts — Diagnose which network layer is blocking a connect.
 *
 * When a WebSocket connection is taking too long, we run this probe and surface
 * the first layer that failed so the user can fix the right thing (toggle radio,
 * reconnect Tailscale, check that the peer host is actually up, etc.).
 *
 * The probe is a pure function of (navigator, fetch, websocket) and returns
 * a list of diagnostic lines. It is independently testable — callers pass in
 * the WebSocket reference so the probe can inspect its live readyState at the
 * moment of evaluation.
 *
 * Layer cascade, shortest path first:
 *
 *   1. navigator.onLine        — radio/wifi off?
 *   2. fetch /version (no-store, 3s timeout) — can we reach MobiSSH at all?
 *   3. ws.readyState           — is the WebSocket even in a connecting state?
 *
 * Each layer contributes one diagnostic line. The caller decides how to render
 * them (toast, overlay log, console). All probes are bounded so the cascade
 * completes in <= 3 seconds on the slowest path.
 */

export type ProbeLine = {
  layer: 'radio' | 'http' | 'websocket';
  ok: boolean;
  message: string;
};

export interface ProbeDeps {
  onLine: boolean;
  fetchImpl: (url: string, init: RequestInit) => Promise<Response>;
  ws: { readyState: number } | null;
  // Relative URL resolved against the document origin. Default: 'version'.
  versionUrl?: string;
  // How long to wait for the HTTP probe before calling it stuck. Default: 3000ms.
  httpTimeoutMs?: number;
}

/** WebSocket constants without requiring a global WebSocket (for tests). */
export const WS_CONNECTING = 0;
export const WS_OPEN = 1;
export const WS_CLOSING = 2;
export const WS_CLOSED = 3;

/**
 * Run the layered probe and return diagnostic lines in the order they were
 * evaluated. The cascade short-circuits on the first failure — subsequent
 * layers report "skipped" so the overall list is a complete trace of what
 * was checked.
 */
export async function probeConnectLayers(deps: ProbeDeps): Promise<ProbeLine[]> {
  const lines: ProbeLine[] = [];

  // Layer 1: radio
  if (!deps.onLine) {
    lines.push({ layer: 'radio', ok: false, message: 'Device reports offline (check Wi-Fi / cellular)' });
    return lines;
  }
  lines.push({ layer: 'radio', ok: true, message: 'Device online' });

  // Layer 2: HTTP to MobiSSH server
  const versionUrl = deps.versionUrl ?? 'version';
  const httpTimeoutMs = deps.httpTimeoutMs ?? 3000;
  const httpResult = await _probeHttp(deps.fetchImpl, versionUrl, httpTimeoutMs);
  lines.push(httpResult);
  if (!httpResult.ok) {
    // HTTP failed but radio is on — most likely Tailscale is disconnected
    // or the production container is down. Don't try the WS layer; it would
    // just be redundant noise.
    return lines;
  }

  // Layer 3: WebSocket readyState
  if (!deps.ws) {
    lines.push({ layer: 'websocket', ok: false, message: 'WebSocket not started (internal — this is a bug)' });
    return lines;
  }

  switch (deps.ws.readyState) {
    case WS_CONNECTING:
      lines.push({
        layer: 'websocket',
        ok: false,
        message: 'HTTP works but WebSocket handshake is stuck — remote SSH host may be offline',
      });
      break;
    case WS_OPEN:
      lines.push({
        layer: 'websocket',
        ok: true,
        message: 'WebSocket open — waiting on SSH authentication',
      });
      break;
    case WS_CLOSING:
    case WS_CLOSED:
      lines.push({
        layer: 'websocket',
        ok: false,
        message: `WebSocket closed before SSH ready (readyState=${String(deps.ws.readyState)})`,
      });
      break;
    default:
      lines.push({
        layer: 'websocket',
        ok: false,
        message: `WebSocket in unexpected state ${String(deps.ws.readyState)}`,
      });
  }

  return lines;
}

async function _probeHttp(
  fetchImpl: (url: string, init: RequestInit) => Promise<Response>,
  url: string,
  timeoutMs: number,
): Promise<ProbeLine> {
  const controller = new AbortController();
  const timer = setTimeout(() => { controller.abort(); }, timeoutMs);
  try {
    const res = await fetchImpl(url, { cache: 'no-store', signal: controller.signal });
    clearTimeout(timer);
    if (!res.ok) {
      return {
        layer: 'http',
        ok: false,
        message: `HTTP ${String(res.status)} from ${url} — server is reachable but unhealthy`,
      };
    }
    return {
      layer: 'http',
      ok: true,
      message: `HTTP 200 from ${url} — MobiSSH server reachable`,
    };
  } catch (err) {
    clearTimeout(timer);
    const name = (err as { name?: string }).name ?? '';
    if (name === 'AbortError') {
      return {
        layer: 'http',
        ok: false,
        message: `No HTTP response from ${url} in ${String(timeoutMs)}ms — check Tailscale connection`,
      };
    }
    return {
      layer: 'http',
      ok: false,
      message: `HTTP request to ${url} failed — check Tailscale connection`,
    };
  }
}
