/**
 * modules/connection.ts — WebSocket SSH connection lifecycle
 *
 * Manages WebSocket connection, SSH authentication, reconnect with
 * exponential backoff, keepalive pings, screen wake lock, host key
 * verification, and visibility-based reconnection.
 */
import { getDefaultWsUrl, RECONNECT, ANSI, escHtml } from './constants.js';
import { appState } from './state.js';
import { stopAndDownloadRecording } from './recording.js';
let _toast = (_msg) => { };
let _setStatus = (_state, _text) => { };
let _focusIME = () => { };
let _applyTabBarVisibility = () => { };
export function initConnection({ toast, setStatus, focusIME, applyTabBarVisibility }) {
    _toast = toast;
    _setStatus = setStatus;
    _focusIME = focusIME;
    _applyTabBarVisibility = applyTabBarVisibility;
}
// ── WebSocket / SSH connection ────────────────────────────────────────────────
export function connect(profile) {
    appState.currentProfile = profile;
    appState.reconnectDelay = RECONNECT.INITIAL_DELAY_MS;
    cancelReconnect();
    _openWebSocket();
}
function _openWebSocket() {
    if (appState.ws) {
        appState.ws.onclose = null;
        appState.ws.close();
        appState.ws = null;
    }
    const wsUrl = localStorage.getItem('wsUrl') ?? getDefaultWsUrl();
    _setStatus('connecting', `Connecting to ${wsUrl}…`);
    appState.terminal?.writeln(ANSI.yellow(`Connecting to ${wsUrl}…`));
    try {
        appState.ws = new WebSocket(wsUrl);
    }
    catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        appState.terminal?.writeln(ANSI.red(`WebSocket error: ${message}`));
        scheduleReconnect();
        return;
    }
    appState.ws.onopen = () => {
        appState._wsConnected = true;
        startKeepAlive();
        if (!appState.currentProfile)
            return;
        const authMsg = {
            type: 'connect',
            host: appState.currentProfile.host,
            port: appState.currentProfile.port || 22,
            username: appState.currentProfile.username,
        };
        if (appState.currentProfile.authType === 'key' && appState.currentProfile.privateKey) {
            authMsg.privateKey = appState.currentProfile.privateKey;
            if (appState.currentProfile.passphrase)
                authMsg.passphrase = appState.currentProfile.passphrase;
        }
        else {
            authMsg.password = appState.currentProfile.password ?? '';
        }
        if (appState.currentProfile.initialCommand)
            authMsg.initialCommand = appState.currentProfile.initialCommand;
        if (localStorage.getItem('allowPrivateHosts') === 'true')
            authMsg.allowPrivate = true;
        appState.ws?.send(JSON.stringify(authMsg));
        appState.terminal?.writeln(ANSI.dim(`SSH → ${appState.currentProfile.username}@${appState.currentProfile.host}:${String(appState.currentProfile.port || 22)}…`));
    };
    appState.ws.onmessage = (event) => {
        let msg;
        try {
            msg = JSON.parse(event.data);
        }
        catch {
            return;
        }
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
                appState.terminal?.writeln(ANSI.green('✓ Connected'));
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
                appState.terminal?.writeln(ANSI.red(`Error: ${msg.message}`));
                break;
            case 'disconnected':
                appState.sshConnected = false;
                _setStatus('disconnected', 'Disconnected');
                appState.terminal?.writeln(ANSI.yellow(`Disconnected: ${msg.reason ?? 'unknown reason'}`));
                stopAndDownloadRecording(); // auto-save recording on SSH disconnect (#54)
                scheduleReconnect();
                break;
            case 'hostkey': { // SSH host key verification (#5)
                const hostKey = `${msg.host}:${String(msg.port)}`;
                const knownHosts = JSON.parse(localStorage.getItem('knownHosts') ?? '{}');
                const known = knownHosts[hostKey];
                if (!known) {
                    _showHostKeyPrompt(msg, null, (accepted) => {
                        if (accepted) {
                            knownHosts[hostKey] = { fingerprint: msg.fingerprint, keyType: msg.keyType, addedAt: new Date().toISOString() };
                            localStorage.setItem('knownHosts', JSON.stringify(knownHosts));
                        }
                        appState.ws?.send(JSON.stringify({ type: 'hostkey_response', accepted }));
                    });
                }
                else if (known.fingerprint === msg.fingerprint) {
                    appState.ws?.send(JSON.stringify({ type: 'hostkey_response', accepted: true }));
                }
                else {
                    _showHostKeyPrompt(msg, known.fingerprint, (accepted) => {
                        if (accepted) {
                            const updated = JSON.parse(localStorage.getItem('knownHosts') ?? '{}');
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
            if (!event.wasClean) {
                appState.terminal?.writeln(ANSI.red('Connection lost.'));
                scheduleReconnect();
            }
        }
    };
    appState.ws.onerror = () => {
        appState.terminal?.writeln(ANSI.red('WebSocket error — check server URL in Settings.'));
    };
}
export function scheduleReconnect() {
    if (!appState.currentProfile)
        return;
    const delaySec = Math.round(appState.reconnectDelay / 1000);
    appState.terminal?.writeln(ANSI.dim(`Reconnecting in ${String(delaySec)}s… (tap ✕ to cancel)`));
    _setStatus('connecting', `Reconnecting in ${String(delaySec)}s…`);
    appState.reconnectTimer = setTimeout(() => {
        appState.reconnectDelay = Math.min(appState.reconnectDelay * RECONNECT.BACKOFF_FACTOR, RECONNECT.MAX_DELAY_MS);
        _openWebSocket();
    }, appState.reconnectDelay);
}
export function cancelReconnect() {
    if (appState.reconnectTimer) {
        clearTimeout(appState.reconnectTimer);
        appState.reconnectTimer = null;
    }
}
export function reconnect() {
    if (appState.currentProfile)
        _openWebSocket();
}
// Application-layer keepalive (#29): sends a ping every 25s so NAT/proxies don't
// drop idle SSH sessions. The server ignores unknown message types gracefully.
const WS_PING_INTERVAL_MS = 25_000;
function startKeepAlive() {
    stopKeepAlive();
    appState.keepAliveTimer = setInterval(() => {
        if (appState.ws?.readyState === WebSocket.OPEN) {
            appState.ws.send(JSON.stringify({ type: 'ping' }));
        }
        else {
            stopKeepAlive();
        }
    }, WS_PING_INTERVAL_MS);
}
function stopKeepAlive() {
    if (appState.keepAliveTimer) {
        clearInterval(appState.keepAliveTimer);
        appState.keepAliveTimer = null;
    }
}
// ── Screen Wake Lock (#43) ────────────────────────────────────────────────────
let _wakeLock = null;
async function acquireWakeLock() {
    if (!('wakeLock' in navigator))
        return;
    try {
        _wakeLock = await navigator.wakeLock.request('screen');
    }
    catch { /* denied (low battery, etc.) — fail silently */ }
}
function releaseWakeLock() {
    if (_wakeLock) {
        void _wakeLock.release().catch(() => { });
        _wakeLock = null;
    }
}
// visibilitychange: immediately reconnect if the session dropped while hidden,
// and reacquire the wake lock if a session is active.
document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') {
        if (appState.sshConnected)
            void acquireWakeLock();
        if (appState.currentProfile && (!appState.ws || appState.ws.readyState !== WebSocket.OPEN)) {
            cancelReconnect();
            _openWebSocket();
        }
    }
    else {
        releaseWakeLock();
    }
});
export function disconnect() {
    stopAndDownloadRecording(); // auto-save any active recording (#54)
    cancelReconnect();
    stopKeepAlive();
    releaseWakeLock();
    appState.currentProfile = null;
    appState.sshConnected = false;
    appState._wsConnected = false;
    if (appState.ws) {
        appState.ws.onclose = null;
        try {
            appState.ws.send(JSON.stringify({ type: 'disconnect' }));
        }
        catch { /* may already be closed */ }
        appState.ws.close();
        appState.ws = null;
    }
    _setStatus('disconnected', 'Disconnected');
    appState.terminal?.writeln(ANSI.yellow('Disconnected.'));
}
export function sendSSHInput(data) {
    if (!appState.sshConnected || !appState.ws || appState.ws.readyState !== WebSocket.OPEN)
        return;
    appState.ws.send(JSON.stringify({ type: 'input', data }));
}
function _showHostKeyPrompt(msg, knownFingerprint, callback) {
    const existing = document.getElementById('hostKeyOverlay');
    if (existing)
        existing.remove();
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
    function dismiss() { overlay.remove(); }
    overlay.querySelector('.hostkey-accept').addEventListener('click', () => { dismiss(); callback(true); });
    overlay.querySelector('.hostkey-reject').addEventListener('click', () => { dismiss(); callback(false); });
}
//# sourceMappingURL=connection.js.map