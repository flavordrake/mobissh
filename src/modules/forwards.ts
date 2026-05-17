/**
 * MobiSSH — Local port-forward client module (Issue #499 slice 1)
 *
 * Responsibilities:
 *  - Fetch and cache bridge capabilities (/capabilities endpoint)
 *  - Open / close local (-L) port forwards via the WS protocol
 *  - Handle incoming fwd_local_* server messages
 *  - Gate the Forwards UI panel on portForward.local capability
 *  - Render forward rows in the Forwards submenu
 *
 * This module is scoped globally (not per-session) for slice 1.
 * It does NOT import connection.ts to avoid circular deps — it reads
 * the active WS via a test seam (setActiveWsForTesting) or directly
 * from the window's appState in production.
 */

import type { Capabilities, LocalForward, ServerMessage } from './types.js';

// ── Module state ─────────────────────────────────────────────────────────────

/** Cached capabilities from /capabilities. Null = not yet loaded. */
let _capabilities: Capabilities | null = null;

/** Active local forwards keyed by id. */
const _forwards = new Map<string, LocalForward>();

/**
 * Pending openLocalForward promises awaiting fwd_local_ready or fwd_local_error.
 * Keyed by forward id.
 */
const _pendingOpens = new Map<string, {
  resolve: (fwd: LocalForward) => void;
  reject: (err: Error & { code?: string }) => void;
  dstHost: string;
  dstPort: number;
}>();

/** Active WebSocket — set by setActiveWsForTesting in tests, or from appState in prod. */
let _activeWs: WebSocket | null = null;

// ── Test seam ─────────────────────────────────────────────────────────────────

/**
 * Inject a fake WebSocket for unit tests.
 * Production code does NOT call this — it reads from connection state instead.
 */
export function setActiveWsForTesting(ws: WebSocket): void {
  _activeWs = ws;
}

/** Get the active WebSocket for sending messages. */
function getWs(): WebSocket | null {
  if (_activeWs) return _activeWs;
  // In production, try to read from global appState if available
  try {
    // Dynamic import would be circular; access via globalThis at runtime
    const gs = globalThis as Record<string, unknown>;
    const appState = gs['appState'] as { sessions?: Map<string, { ws: WebSocket | null }>, activeSessionId?: string | null } | undefined;
    if (appState?.activeSessionId && appState.sessions) {
      const session = appState.sessions.get(appState.activeSessionId);
      return session?.ws ?? null;
    }
  } catch { /* ignore */ }
  return null;
}

// ── Fallback capabilities ─────────────────────────────────────────────────────

const FALLBACK_CAPABILITIES: Capabilities = {
  version: 1,
  bridge: { version: 'unknown', hash: 'unknown' },
  portForward: { local: false, remote: false, dynamic: false },
};

// ── Capabilities ──────────────────────────────────────────────────────────────

/**
 * Load capabilities from the bridge. Caches after first successful fetch.
 * Falls back gracefully on 404 or network error (A7, A8).
 */
export async function loadCapabilities(): Promise<Capabilities> {
  if (_capabilities !== null) return _capabilities;

  try {
    const res = await fetch('/capabilities');
    if (!res.ok) {
      // 404 or other non-success: return fallback, do NOT cache so a new
      // bridge deploy can be detected on next boot.
      console.warn(`[forwards] /capabilities returned ${String(res.status)} — using fallback`);
      _capabilities = { ...FALLBACK_CAPABILITIES };
      return _capabilities;
    }
    const data = await res.json() as Capabilities;
    _capabilities = data;
    return _capabilities;
  } catch (err) {
    // Network error — fall back, warn (do NOT show error dialog per A8)
    console.warn('[forwards] /capabilities fetch failed:', err instanceof Error ? err.message : String(err));
    _capabilities = { ...FALLBACK_CAPABILITIES };
    return _capabilities;
  }
}

/**
 * Directly apply a Capabilities object (used by tests and connection.ts).
 * Also updates the DOM panel gating.
 */
export function applyCapabilities(caps: Capabilities): void {
  _capabilities = caps;
  _applyPanelGating();
}

/** Return the currently cached capabilities (null if not yet loaded). */
export function getCapabilities(): Capabilities | null {
  return _capabilities;
}

// ── ID generation ─────────────────────────────────────────────────────────────

function generateId(): string {
  return `fwd_${Math.random().toString(36).slice(2)}_${Date.now().toString(36)}`;
}

// ── Forward lifecycle ─────────────────────────────────────────────────────────

/**
 * Open a local (-L) port forward.
 *
 * Sends fwd_local_listen to the bridge and returns a Promise that resolves
 * when fwd_local_ready arrives (B1, B2, B3).
 */
export function openLocalForward(srcPort: number, dstHost: string, dstPort: number): Promise<LocalForward> {
  const id = generateId();

  const promise = new Promise<LocalForward>((resolve, reject) => {
    _pendingOpens.set(id, { resolve, reject, dstHost, dstPort });
  });

  const ws = getWs();
  if (ws) {
    ws.send(JSON.stringify({ type: 'fwd_local_listen', id, srcPort, dstHost, dstPort }));
  }

  return promise;
}

/**
 * Close an active local forward (B7).
 * Sends fwd_local_close; entry is removed when fwd_local_closed arrives.
 */
export function closeLocalForward(id: string): Promise<void> {
  const ws = getWs();
  if (ws && ws.readyState === 1 /* OPEN */) {
    ws.send(JSON.stringify({ type: 'fwd_local_close', id }));
  }
  return Promise.resolve();
}

/** List all active forwards. */
export function listForwards(): LocalForward[] {
  return Array.from(_forwards.values());
}

// ── Server message handling ───────────────────────────────────────────────────

/**
 * Stable error codes the server emits via fwd_local_error (D3).
 */
const KNOWN_FORWARD_ERROR_CODES = ['eaddrinuse', 'forward_failed', 'not_supported', 'eaccess', 'eperm', 'privileged_port', 'bad_payload', 'ssh_disconnected'] as const;

export function getKnownForwardErrorCodes(): readonly string[] {
  return KNOWN_FORWARD_ERROR_CODES;
}

/**
 * Dispatch a fwd_local_* server message.
 *
 * EC2: if capabilities have not been loaded (null), fwd_local_* messages that
 * are not in response to a client-initiated fwd_local_listen are silently
 * dropped — protects the remote-PWA case where the Forwards UI is absent.
 * Messages that correspond to a pending open (keyed by id) are always processed
 * because the client explicitly initiated them.
 */
export function handleServerForwardMessage(msg: ServerMessage): void {
  if (!msg.type.startsWith('fwd_local_')) return;

  // EC2 guard: drop if capabilities not loaded AND neither a pending open
  // nor an active forward matches this id.
  // Pending open = client deliberately sent fwd_local_listen.
  // Active forward = server already confirmed via fwd_local_ready.
  // Both cases mean we own this forward and must process server replies.
  const msgId = 'id' in msg ? (msg as { id: string }).id : '';
  const hasPending = _pendingOpens.has(msgId);
  const hasActive = _forwards.has(msgId);
  if (_capabilities === null && !hasPending && !hasActive) {
    console.warn('[forwards] EC2: dropping fwd_local_* message before capabilities loaded:', msg.type);
    return;
  }

  switch (msg.type) {
    case 'fwd_local_ready': {
      const pending = _pendingOpens.get(msg.id);
      const fwd: LocalForward = {
        id: msg.id,
        srcPort: msg.srcPort,
        dstHost: pending?.dstHost ?? '',
        dstPort: pending?.dstPort ?? 0,
        listenAddr: msg.listenAddr,
        state: 'active',
        openedAt: Date.now(),
      };
      _forwards.set(msg.id, fwd);
      _pendingOpens.delete(msg.id);
      pending?.resolve(fwd);
      _renderForwardsIfPanelVisible();
      break;
    }

    case 'fwd_local_error': {
      const pending = _pendingOpens.get(msg.id);
      _pendingOpens.delete(msg.id);
      // Remove any forward entry for this id (it never became active or failed while active)
      _forwards.delete(msg.id);
      if (pending) {
        const err = Object.assign(new Error(msg.message), { code: msg.code });
        pending.reject(err);
      }
      _renderForwardsIfPanelVisible();
      break;
    }

    case 'fwd_local_closed': {
      _forwards.delete(msg.id);
      // Also resolve any still-pending open as rejection (ssh_disconnected case)
      const pending = _pendingOpens.get(msg.id);
      if (pending) {
        _pendingOpens.delete(msg.id);
        pending.reject(Object.assign(new Error(msg.reason), { code: msg.reason }));
      }
      _renderForwardsIfPanelVisible();
      break;
    }

    case 'fwd_local_accept':
      // B4: channel accept — in slice 1 the client doesn't need to take action beyond logging
      console.warn('[forwards] fwd_local_accept channel', msg.channelId, 'for forward', msg.id);
      break;

    case 'fwd_local_data':
      // B5: data frame — in slice 1 the client receives data but the panel only shows
      // metadata. The actual data flow is handled by the server <-> TCP socket.
      break;

    case 'fwd_local_channel_close':
      // B6: channel close — forward itself stays active
      console.warn('[forwards] channel', msg.channelId, 'closed for forward', msg.id, msg.reason ?? '');
      break;

    default:
      // D4: unknown fwd_local_* types — drop without throwing
      console.warn('[forwards] unknown fwd_local_* message type:', (msg as { type: string }).type);
      break;
  }
}

// ── Base64 utilities ──────────────────────────────────────────────────────────

/**
 * Attempt to decode a base64 string to a Uint8Array.
 * Returns null if the input is malformed (EC8).
 */
export function tryDecodeBase64(b64: string): Uint8Array | null {
  try {
    // Validate: base64 chars + optional padding
    if (!/^[A-Za-z0-9+/]*={0,2}$/.test(b64)) return null;
    const binary = atob(b64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }
    return bytes;
  } catch {
    return null;
  }
}

// ── SSH lifecycle hooks ───────────────────────────────────────────────────────

/**
 * Called by connection.ts when the SSH session disconnects.
 * Clears all active forwards (C6). Listening ports are released server-side.
 */
export function onSshDisconnected(): void {
  _forwards.clear();
  _pendingOpens.clear();
  _activeWs = null;
  _renderForwardsIfPanelVisible();
}

/**
 * Called by connection.ts when the SSH session reconnects.
 * Forwards are NOT auto-restored (C6 — slice 1 design decision).
 */
export function onSshReconnected(): void {
  // No-op for slice 1: forwards cleared on disconnect and must be re-opened manually.
  _renderForwardsIfPanelVisible();
}

// ── UI panel ─────────────────────────────────────────────────────────────────

/** IDs of the Forwards submenu elements (must match index.html). */
const BTN_ID = 'sessionForwardsSubmenuBtn';
const PANEL_ID = 'sessionForwardsSubmenu';

/**
 * Apply capability gating to the Forwards panel.
 * Called whenever capabilities change.
 */
function _applyPanelGating(): void {
  if (typeof document === 'undefined') return;
  const btn = document.getElementById(BTN_ID);
  const panel = document.getElementById(PANEL_ID);
  const enabled = _capabilities?.portForward.local === true;
  btn?.classList.toggle('hidden', !enabled);
  panel?.classList.toggle('hidden', !enabled);
}

/**
 * Module self-reference for testability.
 * Vitest's vi.spyOn replaces properties on the module namespace object but
 * does NOT update the internal local binding of named exports. Storing a
 * reference to the exports namespace here lets click handlers call through
 * the current spy at call time rather than the captured-at-definition-time
 * local binding. Set by initForwardsPanel using the `_self` parameter.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
let _selfRef: Record<string, any> | null = null;

/** Get the current `openLocalForward` — goes through spy if one is installed. */
function _callOpen(srcPort: number, dstHost: string, dstPort: number): Promise<LocalForward> {
  if (_selfRef?.['openLocalForward']) {
    return (_selfRef['openLocalForward'] as typeof openLocalForward)(srcPort, dstHost, dstPort);
  }
  return openLocalForward(srcPort, dstHost, dstPort);
}

/** Get the current `closeLocalForward` — goes through spy if one is installed. */
function _callClose(id: string): Promise<void> {
  if (_selfRef?.['closeLocalForward']) {
    return (_selfRef['closeLocalForward'] as typeof closeLocalForward)(id);
  }
  return closeLocalForward(id);
}

/**
 * Wire up the Forwards submenu toggle and "Add forward" flow.
 * Must be called once on app boot (mirrors the Terminal submenu setup in ui.ts).
 *
 * Pass `self` as the module namespace (the object returned by `await import(...)`)
 * so that vi.spyOn() replacements are visible to panel click handlers:
 *   `const mod = await import('../forwards.js'); mod.initForwardsPanel(mod);`
 * Without `self`, production code (no spies) works identically.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function initForwardsPanel(self?: Record<string, any>): void {
  if (typeof document === 'undefined') return;

  _selfRef = self ?? null;

  const btn = document.getElementById(BTN_ID);
  const panel = document.getElementById(PANEL_ID);

  if (!btn || !panel) return;

  // Toggle expand/collapse
  btn.addEventListener('click', (e) => {
    e.stopPropagation();
    const expanded = !panel.classList.contains('hidden');
    panel.classList.toggle('hidden', expanded);
    btn.setAttribute('aria-expanded', expanded ? 'false' : 'true');
  });

  // Render initial (empty) state
  _renderForwardsInPanel(panel);
}

/** Render or re-render forwards rows (C4). May be called externally. */
export function renderForwards(forwards: LocalForward[]): void {
  if (typeof document === 'undefined') return;
  const panel = document.getElementById(PANEL_ID);
  if (!panel) return;
  _renderRows(panel, forwards);
}

function _renderForwardsIfPanelVisible(): void {
  if (typeof document === 'undefined') return;
  const panel = document.getElementById(PANEL_ID);
  if (!panel) return;
  _renderForwardsInPanel(panel);
}

function _renderForwardsInPanel(panel: HTMLElement): void {
  _renderRows(panel, Array.from(_forwards.values()));
}

function _renderRows(panel: HTMLElement, forwards: LocalForward[]): void {
  // Remove existing rows (keep the add-forward controls)
  for (const row of Array.from(panel.querySelectorAll('[data-forward-id]'))) {
    row.remove();
  }

  // Ensure add-forward controls exist
  _ensureAddForwardControls(panel);

  // Insert rows before the add-forward button
  const addBtn = panel.querySelector('[data-action="add-forward"]');
  for (const fwd of forwards) {
    const row = _buildRow(fwd);
    if (addBtn) {
      panel.insertBefore(row, addBtn);
    } else {
      panel.appendChild(row);
    }
  }
}

function _buildRow(fwd: LocalForward): HTMLElement {
  const row = document.createElement('div');
  row.className = 'session-menu-item forwards-row';
  row.setAttribute('data-forward-id', fwd.id);

  const label = document.createElement('span');
  label.className = 'forwards-row-label';
  label.textContent = `${String(fwd.srcPort)} → ${fwd.dstHost}:${String(fwd.dstPort)}`;

  const removeBtn = document.createElement('button');
  removeBtn.className = 'forwards-row-remove';
  removeBtn.setAttribute('data-action', 'remove-forward');
  removeBtn.textContent = 'Remove';
  removeBtn.addEventListener('click', () => {
    void _callClose(fwd.id);
  });

  row.appendChild(label);
  row.appendChild(removeBtn);
  return row;
}

function _ensureAddForwardControls(panel: HTMLElement): void {
  if (panel.querySelector('[data-action="add-forward"]')) return;

  // "Add forward" button
  const addBtn = document.createElement('button');
  addBtn.className = 'session-menu-item';
  addBtn.setAttribute('data-action', 'add-forward');
  addBtn.textContent = '+ Add forward';

  // Add-forward form (hidden by default)
  const form = document.createElement('div');
  form.setAttribute('data-add-forward-form', '');
  form.className = 'hidden forwards-add-form';

  const srcPortInput = document.createElement('input');
  srcPortInput.type = 'number';
  srcPortInput.placeholder = 'Local port';
  srcPortInput.setAttribute('data-add-forward-field', 'srcPort');

  const dstHostInput = document.createElement('input');
  dstHostInput.type = 'text';
  dstHostInput.placeholder = 'Remote host';
  dstHostInput.setAttribute('data-add-forward-field', 'dstHost');

  const dstPortInput = document.createElement('input');
  dstPortInput.type = 'number';
  dstPortInput.placeholder = 'Remote port';
  dstPortInput.setAttribute('data-add-forward-field', 'dstPort');

  const confirmBtn = document.createElement('button');
  confirmBtn.setAttribute('data-action', 'confirm-add-forward');
  confirmBtn.textContent = 'Open';

  const errorEl = document.createElement('div');
  errorEl.setAttribute('data-add-forward-error', '');
  errorEl.className = 'hidden forwards-error';

  form.appendChild(srcPortInput);
  form.appendChild(dstHostInput);
  form.appendChild(dstPortInput);
  form.appendChild(confirmBtn);
  form.appendChild(errorEl);

  // Show form on add-button click
  addBtn.addEventListener('click', () => {
    form.classList.remove('hidden');
    addBtn.classList.add('hidden');
    errorEl.textContent = '';
    errorEl.classList.add('hidden');
  });

  // Confirm: call openLocalForward
  confirmBtn.addEventListener('click', () => {
    const srcPort = parseInt((panel.querySelector('[data-add-forward-field="srcPort"]') as HTMLInputElement).value, 10);
    const dstHost = (panel.querySelector('[data-add-forward-field="dstHost"]') as HTMLInputElement).value.trim();
    const dstPort = parseInt((panel.querySelector('[data-add-forward-field="dstPort"]') as HTMLInputElement).value, 10);

    errorEl.textContent = '';
    errorEl.classList.add('hidden');

    _callOpen(srcPort, dstHost, dstPort).then(() => {
      // Success: hide form, re-show add button
      form.classList.add('hidden');
      addBtn.classList.remove('hidden');
    }).catch((err: unknown) => {
      // C5b: keep form open, show inline error
      const e = err as { code?: string; message?: string };
      const message = e.message ?? String(err);
      const msg = e.code ? `${e.code}: ${message}` : message;
      errorEl.textContent = msg;
      errorEl.classList.remove('hidden');
    });
  });

  panel.appendChild(addBtn);
  panel.appendChild(form);
}
