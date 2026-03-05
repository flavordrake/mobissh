/**
 * modules/connection.ts — WebSocket SSH connection lifecycle
 *
 * Manages WebSocket connection, SSH authentication, reconnect with
 * exponential backoff, keepalive pings, screen wake lock, host key
 * verification, and visibility-based reconnection.
 */

import type { ConnectionDeps, ConnectionStatus, ServerMessage, ConnectMessage, SSHProfile } from './types.js';

type SftpMsg = Extract<ServerMessage, { type: 'sftp_ls_result' | 'sftp_error' }>;
let _sftpHandler: ((msg: SftpMsg) => void) | null = null;
export function setSftpHandler(fn: (msg: SftpMsg) => void): void { _sftpHandler = fn; }
export function sendSftpLs(path: string, requestId: string): void {
  if (!appState.sshConnected || !appState.ws || appState.ws.readyState !== WebSocket.OPEN) return;
  appState.ws.send(JSON.stringify({ type: 'sftp_ls', path, requestId }));
}
import { getDefaultWsUrl, RECONNECT, escHtml } from './constants.js';
import { appState } from './state.js';
import { stopAndDownloadRecording } from './recording.js';

let _toast = (_msg: string): void => {};
let _setStatus = (_state: ConnectionStatus, _text: string): void => {};
let _focusIME = (): void => {};
let _applyTabBarVisibility = (): void => {};

export function initConnection({ toast, setStatus, focusIME, applyTabBarVisibility }: ConnectionDeps): void {
  _toast = toast;
  _setStatus = setStatus;
  _focusIME = focusIME;
  _applyTabBarVisibility = applyTabBarVisibility;
}

// ── WebSocket / SSH connection ────────────────────────────────────────────────

// Max consecutive pre-open WS close events before halting the reconnect loop.
// A close before onopen fires typically indicates a server-side auth rejection.
const WS_MAX_AUTH_FAILURES = 3;
let _wsConsecFailures = 0;

/** Read the HMAC token injected by the server on page load (#93). */
function _getWsToken(): string {
  return document.querySelector<HTMLMetaElement>('meta[name="ws-token"]')?.content ?? '';
}

export function connect(profile: SSHProfile): void {
  appState.currentProfile = profile;
  appState.reconnectDelay = RECONNECT.INITIAL_DELAY_MS;
  _wsConsecFailures = 0;
  cancelReconnect();
  _openWebSocket();
}

function _openWebSocket(): void {
  if (appState.ws) {
    appState.ws.onclose = null;
    appState.ws.close();
    appState.ws = null;
  }

  const baseUrl = localStorage.getItem('wsUrl') ?? getDefaultWsUrl();
  const token = _getWsToken();
  const wsUrl = token ? `${baseUrl}?token=${encodeURIComponent(token)}` : baseUrl;

  _setStatus('connecting', `Connecting to ${baseUrl}…`);
  _showConnectionStatus(`Connecting to ${baseUrl}…`);

  let openedThisAttempt = false;

  try {
    appState.ws = new WebSocket(wsUrl);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    _showConnectionStatus(`WebSocket error: ${message}`);
    scheduleReconnect();
    return;
  }

  appState.ws.onopen = () => {
    openedThisAttempt = true;
    _wsConsecFailures = 0;
    appState._wsConnected = true;
    startKeepAlive();
    if (!appState.currentProfile) return;
    const authMsg: ConnectMessage = {
      type: 'connect',
      host: appState.currentProfile.host,
      port: appState.currentProfile.port || 22,
      username: appState.currentProfile.username,
    };
    if (appState.currentProfile.authType === 'key' && appState.currentProfile.privateKey) {
      authMsg.privateKey = appState.currentProfile.privateKey;
      if (appState.currentProfile.passphrase) authMsg.passphrase = appState.currentProfile.passphrase;
    } else {
      authMsg.password = appState.currentProfile.password ?? '';
    }
    if (appState.currentProfile.initialCommand) authMsg.initialCommand = appState.currentProfile.initialCommand;
    if (localStorage.getItem('allowPrivateHosts') === 'true') authMsg.allowPrivate = true;
    appState.ws?.send(JSON.stringify(authMsg));
    _showConnectionStatus(`SSH → ${appState.currentProfile.username}@${appState.currentProfile.host}:${String(appState.currentProfile.port || 22)}…`);
  };

  appState.ws.onmessage = (event: MessageEvent) => {
    let msg: ServerMessage;
    try { msg = JSON.parse(event.data as string) as ServerMessage; } catch { return; }

    switch (msg.type) {
      case 'connected':
        appState.sshConnected = true;
        appState.reconnectDelay = RECONNECT.INITIAL_DELAY_MS;
        void acquireWakeLock();
        // Reset terminal modes so stale mouse tracking from a previous session
        // doesn't cause scroll gestures to send SGR codes to a plain shell (#81)
        appState.terminal?.reset();
        if (appState.currentProfile) {
          _setStatus('connected', `${appState.currentProfile.username}@${appState.currentProfile.host}`);
        }
        _showConnectionStatus('Connected');
        _dismissConnectionStatus(1500);
        // Sync terminal size to server
        appState.ws?.send(JSON.stringify({ type: 'resize', cols: appState.terminal?.cols ?? 80, rows: appState.terminal?.rows ?? 24 }));
        // On every connect/reconnect: collapse nav chrome for continuous-feel (#36)
        appState.hasConnected = true;
        appState.tabBarVisible = false;
        _applyTabBarVisibility();
        _focusIME();
        break;

      case 'output':
        appState.terminal?.write(msg.data);
        if (appState.recording && appState.recordingStartTime !== null) {
          appState.recordingEvents.push([(Date.now() - appState.recordingStartTime) / 1000, 'o', msg.data]);
        }
        break;

      case 'error':
        _showConnectionStatus(`Error: ${msg.message}`);
        break;

      case 'disconnected':
        appState.sshConnected = false;
        _setStatus('disconnected', 'Disconnected');
        _showConnectionStatus(`Disconnected: ${msg.reason ?? 'unknown reason'}`);
        stopAndDownloadRecording(); // auto-save recording on SSH disconnect (#54)
        scheduleReconnect();
        break;

      case 'sftp_ls_result':
      case 'sftp_error':
        _sftpHandler?.(msg);
        break;

      case 'hostkey': { // SSH host key verification (#5)
        const hostKey = `${msg.host}:${String(msg.port)}`;
        const knownHosts = JSON.parse(localStorage.getItem('knownHosts') ?? '{}') as Record<string, KnownHost | undefined>;
        const known = knownHosts[hostKey];

        if (!known) {
          _showHostKeyPrompt(msg, null, (accepted) => {
            if (accepted) {
              knownHosts[hostKey] = { fingerprint: msg.fingerprint, keyType: msg.keyType, addedAt: new Date().toISOString() };
              localStorage.setItem('knownHosts', JSON.stringify(knownHosts));
            }
            appState.ws?.send(JSON.stringify({ type: 'hostkey_response', accepted }));
          });
        } else if (known.fingerprint === msg.fingerprint) {
          appState.ws?.send(JSON.stringify({ type: 'hostkey_response', accepted: true }));
        } else {
          _showHostKeyPrompt(msg, known.fingerprint, (accepted) => {
            if (accepted) {
              const updated = JSON.parse(localStorage.getItem('knownHosts') ?? '{}') as Record<string, KnownHost>;
              updated[hostKey] = { fingerprint: msg.fingerprint, keyType: msg.keyType, addedAt: new Date().toISOString() };
              localStorage.setItem('knownHosts', JSON.stringify(updated));
            }
            appState.ws?.send(JSON.stringify({ type: 'hostkey_response', accepted }));
          });
        }
        break;
      }
    }
  };

  appState.ws.onclose = (event) => {
    appState._wsConnected = false;
    appState.sshConnected = false;
    stopKeepAlive();
    if (appState.currentProfile) {
      _setStatus('disconnected', 'Disconnected');
      if (!openedThisAttempt) {
        // Connection closed before onopen — likely an auth rejection (HTTP 401).
        _wsConsecFailures++;
        if (_wsConsecFailures >= WS_MAX_AUTH_FAILURES) {
          _wsConsecFailures = 0;
          _showConnectionStatus('Connection rejected repeatedly. Your session token may have expired — reload the page to get a fresh one.');
          _setStatus('disconnected', 'Auth failed — reload to reconnect');
          return; // stop the reconnect loop
        }
        _showConnectionStatus('Connection lost.');
        scheduleReconnect();
      } else {
        _wsConsecFailures = 0;
        if (!event.wasClean) {
          _showConnectionStatus('Connection lost.');
          scheduleReconnect();
        }
      }
    }
  };

  appState.ws.onerror = () => {
    _showConnectionStatus('WebSocket error — check server URL in Settings.');
  };
}

export function scheduleReconnect(): void {
  if (!appState.currentProfile) return;

  const delaySec = Math.round(appState.reconnectDelay / 1000);
  _toast(`Reconnecting in ${String(delaySec)}s…`);
  _setStatus('connecting', `Reconnecting in ${String(delaySec)}s…`);
  _showConnectionStatus(`Reconnecting in ${String(delaySec)}s…`, { cancelable: true });

  appState.reconnectTimer = setTimeout(() => {
    appState.reconnectDelay = Math.min(
      appState.reconnectDelay * RECONNECT.BACKOFF_FACTOR,
      RECONNECT.MAX_DELAY_MS
    );
    _openWebSocket();
  }, appState.reconnectDelay);
}

export function cancelReconnect(): void {
  if (appState.reconnectTimer) {
    clearTimeout(appState.reconnectTimer);
    appState.reconnectTimer = null;
  }
}

export function reconnect(): void {
  if (appState.currentProfile) _openWebSocket();
}

// Application-layer keepalive (#29): sends a ping every 25s so NAT/proxies don't
// drop idle SSH sessions. The server ignores unknown message types gracefully.
const WS_PING_INTERVAL_MS = 25_000;

function startKeepAlive(): void {
  stopKeepAlive();
  appState.keepAliveTimer = setInterval(() => {
    if (appState.ws?.readyState === WebSocket.OPEN) {
      appState.ws.send(JSON.stringify({ type: 'ping' }));
    } else {
      stopKeepAlive();
    }
  }, WS_PING_INTERVAL_MS);
}

function stopKeepAlive(): void {
  if (appState.keepAliveTimer) {
    clearInterval(appState.keepAliveTimer);
    appState.keepAliveTimer = null;
  }
}

// ── Screen Wake Lock (#43) ────────────────────────────────────────────────────
let _wakeLock: WakeLockSentinel | null = null;

async function acquireWakeLock(): Promise<void> {
  if (!('wakeLock' in navigator)) return;
  try {
    _wakeLock = await navigator.wakeLock.request('screen');
  } catch { /* denied (low battery, etc.) — fail silently */ }
}

function releaseWakeLock(): void {
  if (_wakeLock) {
    void _wakeLock.release().catch(() => {});
    _wakeLock = null;
  }
}

// visibilitychange: immediately reconnect if the session dropped while hidden,
// and reacquire the wake lock if a session is active.
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') {
    if (appState.sshConnected) void acquireWakeLock();
    if (appState.currentProfile && (!appState.ws || appState.ws.readyState !== WebSocket.OPEN)) {
      cancelReconnect();
      _openWebSocket();
    }
  } else {
    releaseWakeLock();
  }
});

export function disconnect(): void {
  stopAndDownloadRecording(); // auto-save any active recording (#54)
  cancelReconnect();
  stopKeepAlive();
  releaseWakeLock();
  appState.currentProfile = null;
  appState.sshConnected = false;
  appState._wsConnected = false;

  if (appState.ws) {
    appState.ws.onclose = null;
    try { appState.ws.send(JSON.stringify({ type: 'disconnect' })); } catch { /* may already be closed */ }
    appState.ws.close();
    appState.ws = null;
  }

  _setStatus('disconnected', 'Disconnected');
  _showConnectionStatus('Disconnected.');
}

export function sendSSHInput(data: string): void {
  if (!appState.sshConnected || !appState.ws || appState.ws.readyState !== WebSocket.OPEN) return;
  appState.ws.send(JSON.stringify({ type: 'input', data }));
}

// ── Connection status overlay (#172) ─────────────────────────────────────────

let _currentOverlay: HTMLDivElement | null = null;

function _showConnectionStatus(message: string, options?: { cancelable?: boolean }): void {
  const cancelable = options?.cancelable ?? false;

  // Reuse existing overlay — append message to scrollable log
  if (_currentOverlay) {
    const log = _currentOverlay.querySelector('.conn-status-log');
    if (log) {
      const line = document.createElement('div');
      line.className = 'conn-status-message';
      line.textContent = message;
      log.appendChild(line);
      log.scrollTop = log.scrollHeight;
    }
    // Update cancel button visibility
    const existingCancel = _currentOverlay.querySelector('.conn-status-cancel');
    if (cancelable && !existingCancel) {
      const btn = document.createElement('button');
      btn.className = 'conn-status-cancel';
      btn.textContent = 'Cancel';
      btn.addEventListener('click', () => {
        cancelReconnect();
        _setStatus('disconnected', 'Reconnect cancelled');
        _currentOverlay?.remove();
        _currentOverlay = null;
      });
      _currentOverlay.querySelector('.conn-status-dialog')!.appendChild(btn);
    } else if (!cancelable && existingCancel) {
      existingCancel.remove();
    }
    return;
  }

  const overlay = document.createElement('div');
  overlay.id = 'connectionStatusOverlay';
  overlay.className = 'conn-status-overlay';

  const dialog = document.createElement('div');
  dialog.className = 'conn-status-dialog';

  const log = document.createElement('div');
  log.className = 'conn-status-log';
  const line = document.createElement('div');
  line.className = 'conn-status-message';
  line.textContent = message;
  log.appendChild(line);
  dialog.appendChild(log);

  if (cancelable) {
    const btn = document.createElement('button');
    btn.className = 'conn-status-cancel';
    btn.textContent = 'Cancel';
    btn.addEventListener('click', () => {
      cancelReconnect();
      _setStatus('disconnected', 'Reconnect cancelled');
      overlay.remove();
      _currentOverlay = null;
    });
    dialog.appendChild(btn);
  }

  overlay.appendChild(dialog);
  document.body.appendChild(overlay);
  _currentOverlay = overlay;
}

function _dismissConnectionStatus(delayMs = 0): void {
  const target = _currentOverlay;
  const remove = (): void => {
    if (target !== null && target === _currentOverlay) {
      target.remove();
      _currentOverlay = null;
    }
  };
  if (delayMs > 0) setTimeout(remove, delayMs); else remove();
}

// ── Host key verification prompt (#5) ─────────────────────────────────────────

interface KnownHost {
  fingerprint: string;
  keyType: string;
  addedAt: string;
}

interface HostKeyMsg {
  host: string;
  port: number;
  keyType: string;
  fingerprint: string;
}

function _showHostKeyPrompt(msg: HostKeyMsg, knownFingerprint: string | null, callback: (accepted: boolean) => void): void {
  const existing = document.getElementById('hostKeyOverlay');
  if (existing) existing.remove();

  const isMismatch = knownFingerprint !== null;

  const overlay = document.createElement('div');
  overlay.id = 'hostKeyOverlay';
  overlay.className = 'hostkey-overlay';
  overlay.innerHTML = `
    <div class="hostkey-dialog">
      <div class="hostkey-title${isMismatch ? ' hostkey-title-warn' : ''}">
        ${isMismatch ? '&#9888; HOST KEY MISMATCH' : 'New SSH Host Key'}
      </div>
      <div class="hostkey-row">
        <span class="hostkey-label">Host</span>
        <code class="hostkey-val">${escHtml(msg.host)}:${String(msg.port)}</code>
      </div>
      <div class="hostkey-row">
        <span class="hostkey-label">Type</span>
        <code class="hostkey-val">${escHtml(msg.keyType)}</code>
      </div>
      ${isMismatch ? `
      <div class="hostkey-row">
        <span class="hostkey-label">Stored fingerprint</span>
        <code class="hostkey-val hostkey-fp-old">${escHtml(knownFingerprint)}</code>
      </div>
      <div class="hostkey-row">
        <span class="hostkey-label">Received fingerprint</span>
        <code class="hostkey-val">${escHtml(msg.fingerprint)}</code>
      </div>
      <div class="hostkey-warn-text">This could indicate a MITM attack. Reject unless you know the key changed.</div>
      ` : `
      <div class="hostkey-row">
        <span class="hostkey-label">Fingerprint</span>
        <code class="hostkey-val">${escHtml(msg.fingerprint)}</code>
      </div>
      <div class="hostkey-info-text">Verify this fingerprint out-of-band before accepting.</div>
      `}
      <div class="hostkey-buttons">
        <button class="hostkey-btn hostkey-reject">Reject</button>
        <button class="hostkey-btn hostkey-accept">${isMismatch ? 'Accept New Key' : 'Accept &amp; Store'}</button>
      </div>
    </div>
  `;

  document.body.appendChild(overlay);

  function dismiss(): void { overlay.remove(); }

  overlay.querySelector('.hostkey-accept')!.addEventListener('click', () => { dismiss(); callback(true); });
  overlay.querySelector('.hostkey-reject')!.addEventListener('click', () => { dismiss(); callback(false); });
}
