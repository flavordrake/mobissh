/**
 * modules/connection.ts — WebSocket SSH connection lifecycle
 *
 * Manages WebSocket connection, SSH authentication, reconnect with
 * exponential backoff, keepalive pings, screen wake lock, host key
 * verification, and visibility-based reconnection.
 */

import type { ConnectionDeps, ConnectionStatus, ServerMessage, ConnectMessage, SSHProfile } from './types.js';
import { vaultLoad } from './vault.js';
import { showErrorDialog, navigateToPanel } from './ui.js';

// Sessions that should navigate to the terminal panel when SSH connects.
// Populated by _openWebSocket for user-initiated connections (not reconnects).
const _pendingNavigateSessions = new Set<string>();

// [SFTP_MSG] -- keep in sync with types.ts SERVER_MESSAGE sftp types and WS router below
type SftpMsg = Extract<ServerMessage, { type: 'sftp_ls_result' | 'sftp_error' | 'sftp_download_result' | 'sftp_download_meta' | 'sftp_download_chunk' | 'sftp_download_end' | 'sftp_upload_result' | 'sftp_upload_ack' | 'sftp_stat_result' | 'sftp_rename_result' | 'sftp_delete_result' | 'sftp_realpath_result' }>;
let _sftpHandler: ((msg: SftpMsg) => void) | null = null;
export function setSftpHandler(fn: (msg: SftpMsg) => void): void { _sftpHandler = fn; }

export const CHUNK_SIZE = 192 * 1024; // 192 KB per chunk

// Pending ack resolvers: requestId -> resolve function
const _ackResolvers = new Map<string, (offset: number) => void>();

/** Base64-encode a Uint8Array without btoa+fromCharCode (which fails on large arrays). */
export function _uint8ToBase64(bytes: Uint8Array): string {
  const BLOCK = 0x8000; // 32 KB blocks to avoid call stack overflow
  let binary = '';
  for (let i = 0; i < bytes.length; i += BLOCK) {
    const slice = bytes.subarray(i, Math.min(i + BLOCK, bytes.length));
    binary += String.fromCharCode.apply(null, slice as unknown as number[]);
  }
  return btoa(binary);
}

/** Wait for a server ack for the given requestId. Returns the acked offset. */
function _waitForAck(requestId: string): Promise<number> {
  return new Promise((resolve) => {
    _ackResolvers.set(requestId, resolve);
  });
}

export interface UploadProgress {
  bytesSent: number;
  totalBytes: number;
}

/**
 * Upload a file in chunks via the SFTP bridge.
 * Sends sftp_upload_start, waits for ack, streams chunks, sends sftp_upload_end.
 * Throws if cancelled or WS disconnects.
 */
export async function uploadFileChunked(
  path: string,
  file: File,
  requestId: string,
  onProgress: (p: UploadProgress) => void
): Promise<void> {
  const session = currentSession();
  if (!session?.ws || session.ws.readyState !== WebSocket.OPEN) {
    throw new Error('Not connected');
  }

  const trace = localStorage.getItem('transferTracing') !== 'false';
  const t0 = performance.now();
  let chunkCount = 0;
  let totalReadMs = 0;
  let totalEncodeMs = 0;
  let totalAckMs = 0;

  // Compute a simple fingerprint (size + name) for server-side dedup
  const fingerprint = `${String(file.size)}-${file.name}`;

  // Send start message
  session.ws.send(JSON.stringify({
    type: 'sftp_upload_start',
    path,
    size: file.size,
    fingerprint,
    requestId
  }));

  // Wait for initial ack — offset > 0 means server has partial data from a previous attempt
  const tAck0 = performance.now();
  const resumeOffset = await _waitForAck(requestId);
  if (trace) console.log(`[transfer:${requestId.slice(-6)}] start ack=${(performance.now() - tAck0).toFixed(0)}ms resume=${String(resumeOffset)}`);

  // Stream chunks
  const reader = file.stream().getReader();
  let bytesSent = 0;
  let bytesSkipped = 0;

  try {
    for (;;) {
      const tRead = performance.now();
      const { done, value } = await reader.read();
      const readMs = performance.now() - tRead;
      totalReadMs += readMs;
      if (done) break;

      // Process the chunk in CHUNK_SIZE pieces
      let offset = 0;
      while (offset < value.length) {
        // Skip bytes the server already has from a previous partial upload (#123)
        if (bytesSkipped < resumeOffset) {
          const remaining = resumeOffset - bytesSkipped;
          const skip = Math.min(remaining, value.length - offset);
          bytesSkipped += skip;
          offset += skip;
          bytesSent += skip;
          onProgress({ bytesSent, totalBytes: file.size });
          continue;
        }

        // Runtime check: ws may change across await boundaries
        const ws = currentSession()?.ws;
        // eslint-disable-next-line @typescript-eslint/no-unnecessary-condition
        if (!ws || ws.readyState !== WebSocket.OPEN) {
          throw new Error('Connection lost during upload');
        }

        const end = Math.min(offset + CHUNK_SIZE, value.length);
        const chunk = value.subarray(offset, end);

        const tEncode = performance.now();
        const data = _uint8ToBase64(chunk);
        const encodeMs = performance.now() - tEncode;
        totalEncodeMs += encodeMs;

        const buffered = ws.bufferedAmount;
        ws.send(JSON.stringify({
          type: 'sftp_upload_chunk',
          requestId,
          data,
          offset: bytesSent
        }));

        // Wait for server ack before sending next chunk
        const tAck = performance.now();
        await _waitForAck(requestId);
        const ackMs = performance.now() - tAck;
        totalAckMs += ackMs;

        chunkCount++;
        bytesSent += chunk.length;
        onProgress({ bytesSent, totalBytes: file.size });
        offset = end;

        if (trace) {
          console.log(`[transfer:${requestId.slice(-6)}] chunk ${String(chunkCount)} read=${readMs.toFixed(0)}ms encode=${encodeMs.toFixed(0)}ms ack=${ackMs.toFixed(0)}ms buffered=${String(buffered)}`);
        }
      }
    }
  } finally {
    reader.releaseLock();
  }

  if (trace) {
    const elapsed = performance.now() - t0;
    const throughput = bytesSent > 0 ? (bytesSent / (elapsed / 1000) / 1024).toFixed(0) : '0';
    console.log(`[transfer:${requestId.slice(-6)}] DONE ${String(chunkCount)} chunks ${(elapsed / 1000).toFixed(1)}s ${throughput} KB/s | read=${totalReadMs.toFixed(0)}ms encode=${totalEncodeMs.toFixed(0)}ms ack_wait=${totalAckMs.toFixed(0)}ms (${(totalAckMs / elapsed * 100).toFixed(0)}% ack-bound)`);
  }

  // Send end message and wait for server confirmation
  const endWs = currentSession()?.ws;
  // eslint-disable-next-line @typescript-eslint/no-unnecessary-condition
  if (endWs && endWs.readyState === WebSocket.OPEN) {
    endWs.send(JSON.stringify({
      type: 'sftp_upload_end',
      requestId
    }));
    // Wait for the server's sftp_upload_result (routed through sftpHandler).
    // Timeout: 10s in production, shorter in test (vitest sets __vitest_worker__).
    // eslint-disable-next-line @typescript-eslint/no-unnecessary-condition
    const isTest = typeof globalThis !== 'undefined' && '__vitest_worker__' in (globalThis as Record<string, unknown>);
    const resultTimeout = isTest ? 100 : 10000;
    await new Promise<void>((resolve) => {
      const timeout = setTimeout(resolve, resultTimeout);
      const origHandler = _sftpHandler;
      _sftpHandler = (msg) => {
        origHandler?.(msg);
        if (msg.type === 'sftp_upload_result' && msg.requestId === requestId) {
          clearTimeout(timeout);
          _sftpHandler = origHandler;
          resolve();
        }
      };
    });
  }
}

export function sendSftpUploadCancel(requestId: string): void {
  // Reject any pending ack so the upload loop throws
  _ackResolvers.delete(requestId);
  const session = currentSession();
  if (!session || !isSessionConnected(session) || !session.ws || session.ws.readyState !== WebSocket.OPEN) return;
  session.ws.send(JSON.stringify({ type: 'sftp_upload_cancel', requestId }));
}

/** Resolve a pending ack. Called from the WS message handler. */
export function _resolveAck(requestId: string, offset: number): void {
  const resolve = _ackResolvers.get(requestId);
  if (resolve) {
    _ackResolvers.delete(requestId);
    resolve(offset);
  }
}
export function sendSftpLs(path: string, requestId: string): void {
  const session = currentSession();
  if (!session || !isSessionConnected(session) || !session.ws || session.ws.readyState !== WebSocket.OPEN) return;
  session.ws.send(JSON.stringify({ type: 'sftp_ls', path, requestId }));
}
export function sendSftpDownload(path: string, requestId: string): void {
  const session = currentSession();
  if (!session || !isSessionConnected(session) || !session.ws || session.ws.readyState !== WebSocket.OPEN) return;
  session.ws.send(JSON.stringify({ type: 'sftp_download', path, requestId }));
}
export function sendSftpUpload(path: string, data: string, requestId: string): void {
  const session = currentSession();
  if (!session || !isSessionConnected(session) || !session.ws || session.ws.readyState !== WebSocket.OPEN) return;
  session.ws.send(JSON.stringify({ type: 'sftp_upload', path, data, requestId }));
}
export function sendSftpRename(oldPath: string, newPath: string, requestId: string): void {
  const session = currentSession();
  if (!session || !isSessionConnected(session) || !session.ws || session.ws.readyState !== WebSocket.OPEN) return;
  session.ws.send(JSON.stringify({ type: 'sftp_rename', oldPath, newPath, requestId }));
}
export function sendSftpDelete(path: string, requestId: string): void {
  const session = currentSession();
  if (!session || !isSessionConnected(session) || !session.ws || session.ws.readyState !== WebSocket.OPEN) return;
  session.ws.send(JSON.stringify({ type: 'sftp_delete', path, requestId }));
}
export function sendSftpRealpath(requestId: string): void {
  const session = currentSession();
  if (!session || !isSessionConnected(session) || !session.ws || session.ws.readyState !== WebSocket.OPEN) return;
  session.ws.send(JSON.stringify({ type: 'sftp_realpath', requestId }));
}
import { getDefaultWsUrl, RECONNECT, escHtml } from './constants.js';
import { appState, currentSession, createSession, transitionSession, isSessionConnected } from './state.js';
import { createSessionTerminal } from './terminal.js';
import { rebindSelectionWatcher } from './selection.js';
import { renderSessionList, closeSession } from './ui.js';
import { stopAndDownloadRecording } from './recording.js';

let _toast = (_msg: string): void => {};
let _setStatus = (_state: ConnectionStatus, _text: string): void => {};

// ── Terminal write batching (#185) ──────────────────────────────────────────
// Buffer incoming SSH output and flush to xterm.js once per animation frame.
// On slow connections, many small chunks arrive faster than the renderer can
// process them, causing visible replay/scrollback jumps. Batching coalesces
// writes into a single terminal.write() per frame.
// Per-session write buffers so output doesn't bleed across sessions
const _writeBufs = new Map<string, string>();
const _writeRafs = new Map<string, number>();

function _flushTerminalWrite(sessionId: string): void {
  _writeRafs.delete(sessionId);
  const session = appState.sessions.get(sessionId);
  const buf = _writeBufs.get(sessionId) ?? '';
  if (buf && session?.terminal) {
    session.terminal.write(buf);
    _writeBufs.set(sessionId, '');
  }
}

function _bufferTerminalWrite(sessionId: string, data: string): void {
  _writeBufs.set(sessionId, (_writeBufs.get(sessionId) ?? '') + data);
  if (!_writeRafs.has(sessionId)) {
    _writeRafs.set(sessionId, requestAnimationFrame(() => { _flushTerminalWrite(sessionId); }));
  }
}
let _focusIME = (): void => {};
let _applyTabBarVisibility = (): void => {};

export function initConnection({ toast, setStatus, focusIME, applyTabBarVisibility }: ConnectionDeps): void {
  _toast = toast;
  _setStatus = setStatus;
  _focusIME = focusIME;
  _applyTabBarVisibility = applyTabBarVisibility;
}

// In-memory passphrase cache keyed by keyVaultId. Cleared on page unload.
const _keyPassphraseCache = new Map<string, string>();

window.addEventListener('beforeunload', () => {
  _keyPassphraseCache.clear();
});

/** Exported for testing only. */
export function _getPassphraseCache(): Map<string, string> {
  return _keyPassphraseCache;
}

/** Returns true if the PEM key data appears to be passphrase-encrypted. */
export function _isKeyEncrypted(keyData: string): boolean {
  // Old-format PEM keys (RSA/DSA/EC) contain "ENCRYPTED" in the header
  if (keyData.includes('ENCRYPTED')) return true;

  // New-format OpenSSH keys: parse binary header to check cipher field
  if (keyData.includes('-----BEGIN OPENSSH PRIVATE KEY-----')) {
    try {
      const b64 = keyData
        .replace(/-----BEGIN OPENSSH PRIVATE KEY-----/, '')
        .replace(/-----END OPENSSH PRIVATE KEY-----/, '')
        .replace(/\s+/g, '');
      const bin = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));

      // AUTH_MAGIC = "openssh-key-v1\0" (15 bytes)
      const magic = 'openssh-key-v1\0';
      if (bin.length < magic.length + 4) return true; // too short, assume encrypted

      for (let i = 0; i < magic.length; i++) {
        if (bin[i] !== magic.charCodeAt(i)) return true; // bad magic, assume encrypted
      }

      // Read ciphername length (4-byte big-endian) then ciphername string
      const offset = magic.length;
      const b0 = bin[offset] ?? 0;
      const b1 = bin[offset + 1] ?? 0;
      const b2 = bin[offset + 2] ?? 0;
      const b3 = bin[offset + 3] ?? 0;
      const cipherLen = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3;
      if (cipherLen <= 0 || offset + 4 + cipherLen > bin.length) return true; // invalid, assume encrypted

      const cipherName = new TextDecoder().decode(bin.slice(offset + 4, offset + 4 + cipherLen));
      return cipherName !== 'none';
    } catch {
      return true; // parsing failed, assume encrypted (safe default)
    }
  }

  return false;
}

/** Show the passphrase prompt dialog and return the entered passphrase, or null on cancel. */
function _promptPassphrase(): Promise<string | null> {
  return new Promise((resolve) => {
    const overlay = document.getElementById('keyPassphraseOverlay');
    const input = document.getElementById('keyPassphraseInput') as HTMLInputElement | null;
    const okBtn = document.getElementById('keyPassphraseOk');
    const cancelBtn = document.getElementById('keyPassphraseCancel');
    const errorEl = document.getElementById('keyPassphraseError');

    if (!overlay || !input || !okBtn || !cancelBtn) {
      resolve(null);
      return;
    }

    input.value = '';
    errorEl?.classList.add('hidden');
    overlay.classList.remove('hidden');
    input.focus();

    function cleanup(): void {
      overlay!.classList.add('hidden');
      okBtn!.removeEventListener('click', onOk);
      cancelBtn!.removeEventListener('click', onCancel);
      input!.removeEventListener('keydown', onKeydown);
    }

    function onOk(): void {
      cleanup();
      resolve(input!.value);
    }

    function onCancel(): void {
      cleanup();
      resolve(null);
    }

    function onKeydown(e: KeyboardEvent): void {
      if (e.key === 'Enter') { e.preventDefault(); onOk(); }
      if (e.key === 'Escape') { e.preventDefault(); onCancel(); }
    }

    okBtn.addEventListener('click', onOk);
    cancelBtn.addEventListener('click', onCancel);
    input.addEventListener('keydown', onKeydown);
  });
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

export async function connect(profile: SSHProfile): Promise<void> {
  // If the profile references a stored key, load the key data from vault
  if (profile.authType === 'key' && profile.keyVaultId && !profile.privateKey) {
    const keyCreds = await vaultLoad(profile.keyVaultId);
    if (keyCreds?.data) {
      profile.privateKey = keyCreds.data as string;
    } else {
      _toast('Could not load stored key from vault.');
      return;
    }
  }

  // If the key is encrypted and no passphrase is set, check cache or prompt
  if (profile.authType === 'key' && profile.privateKey && _isKeyEncrypted(profile.privateKey) && !profile.passphrase) {
    const cacheKey = profile.keyVaultId ?? '';
    const cached = cacheKey ? _keyPassphraseCache.get(cacheKey) : undefined;
    if (cached !== undefined) {
      profile.passphrase = cached;
    } else {
      const passphrase = await _promptPassphrase();
      if (passphrase === null) {
        _toast('Connection cancelled.');
        return;
      }
      profile.passphrase = passphrase;
      if (cacheKey) _keyPassphraseCache.set(cacheKey, passphrase);
    }
  }

  _wsConsecFailures = 0;
  cancelReconnect();

  // Create a SessionState entry for multi-session infrastructure (#59)
  const sessionId = `${profile.host}:${String(profile.port || 22)}:${profile.username}:${String(Date.now())}`;
  const session = createSession(sessionId);
  session.profile = profile;
  session.reconnectDelay = RECONNECT.INITIAL_DELAY_MS;
  appState.activeSessionId = sessionId;

  // Create per-session terminal instance (#261)
  const { terminal, fitAddon } = createSessionTerminal(sessionId);
  session.terminal = terminal;
  session.fitAddon = fitAddon;

  // terminal.onData is registered in _openWebSocket as part of the connection cycle (#334)

  // Hide all other session containers (including lobby), show the new one
  document.querySelectorAll<HTMLElement>('#terminal > [data-session-id]').forEach((el) => {
    el.classList.toggle('hidden', el.dataset.sessionId !== sessionId);
  });

  // Re-bind selection watcher to the new session's terminal (#283)
  rebindSelectionWatcher();

  // Update session list so user can switch between sessions
  renderSessionList();

  _openWebSocket();
}

function _openWebSocket(options?: { silent?: boolean; sessionId?: string }): void {
  const silent = options?.silent ?? false;
  const sessionId = options?.sessionId ?? appState.activeSessionId ?? '';
  const session = appState.sessions.get(sessionId) ?? null;

  // User-initiated connections navigate to terminal once SSH is established (#309)
  if (!silent && sessionId) _pendingNavigateSessions.add(sessionId);

  if (session?.ws) {
    session.ws.onclose = null;
    session.ws.close();
    session.ws = null;
  }

  const baseUrl = localStorage.getItem('wsUrl') ?? getDefaultWsUrl();
  const token = _getWsToken();
  const wsUrl = token ? `${baseUrl}?token=${encodeURIComponent(token)}` : baseUrl;

  _setStatus('connecting', `Connecting to ${baseUrl}…`);
  // Only show status overlay after 5s timeout — happy path never shows it
  let _connectTimeout: ReturnType<typeof setTimeout> | null = null;
  if (!silent) {
    _connectTimeout = setTimeout(() => {
      _connectTimeout = null;
      _showConnectionStatus(`Connecting to ${baseUrl}…`);
    }, 5000);
  }

  let openedThisAttempt = false;
  let newWs: WebSocket;

  try {
    newWs = new WebSocket(wsUrl);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    _showConnectionStatus(`WebSocket error: ${message}`, { error: true });
    scheduleReconnect();
    return;
  }

  // Transition BEFORE assigning session.ws so the 'connecting'/'reconnecting'
  // side-effects clean up the OLD WS (or no-op if null), not the new one (#331).
  if (session) {
    if (session.state === 'idle') transitionSession(sessionId, 'connecting');
    else if (session.state === 'soft_disconnected') transitionSession(sessionId, 'reconnecting');
  }

  // Create a new connection cycle — AbortController signal auto-removes all
  // addEventListener listeners when aborted, eliminating manual handler cleanup (#334).
  if (session) {
    session._cycle = { controller: new AbortController(), disposables: [] };
  }
  const signal = session?._cycle?.controller.signal;

  if (session) session.ws = newWs;

  // Register terminal.onData in the cycle so reconnects get a fresh listener (#334)
  if (session?.terminal) {
    const onDataDisp = session.terminal.onData((data: string) => { sendSSHInput(data); });
    session._cycle?.disposables.push(onDataDisp);
    session._onDataDisposable = onDataDisp;
  }

  newWs.addEventListener('open', () => {
    openedThisAttempt = true;
    _wsConsecFailures = 0;
    startKeepAlive(sessionId);
    const profile = session?.profile;
    if (!profile) return;
    const authMsg: ConnectMessage = {
      type: 'connect',
      host: profile.host,
      port: profile.port || 22,
      username: profile.username,
    };
    if (profile.authType === 'key' && profile.privateKey) {
      authMsg.privateKey = profile.privateKey;
      if (profile.passphrase) authMsg.passphrase = profile.passphrase;
    } else {
      authMsg.password = profile.password ?? '';
    }
    if (profile.initialCommand) authMsg.initialCommand = profile.initialCommand;
    if (localStorage.getItem('allowPrivateHosts') === 'true') authMsg.allowPrivate = true;
    newWs.send(JSON.stringify(authMsg));
    // Status overlay only shows if the 5s timeout already fired
    if (!silent && _currentOverlay) _showConnectionStatus(`SSH → ${profile.username}@${profile.host}:${String(profile.port || 22)}…`);
  }, signal ? { signal } : undefined);

  newWs.addEventListener('message', (event: MessageEvent) => {
    let msg: ServerMessage;
    try { msg = JSON.parse(event.data as string) as ServerMessage; } catch { return; }

    switch (msg.type) {
      case 'connected':
        if (session) {
          if (session.state === 'connecting' || session.state === 'reconnecting') transitionSession(sessionId, 'authenticating');
          if (session.state === 'authenticating') transitionSession(sessionId, 'connected');
        }
        void acquireWakeLock();
        // Reset terminal modes so stale mouse tracking from a previous session
        // doesn't cause scroll gestures to send SGR codes to a plain shell (#81)
        session?.terminal?.reset();
        if (session?.profile) {
          _setStatus('connected', `${session.profile.username}@${session.profile.host}`);
        }
        // Cancel the 5s timeout if it hasn't fired yet
        if (_connectTimeout) { clearTimeout(_connectTimeout); _connectTimeout = null; }
        // Dismiss any visible overlay (happy path: overlay never appeared)
        _dismissConnectionStatus();
        // Navigate to terminal now that SSH is established (#309).
        // Only for user-initiated connections — reconnects don't navigate.
        if (_pendingNavigateSessions.delete(sessionId)) {
          navigateToPanel('terminal');
        }
        // Sync terminal size to server — if the session's container is visible,
        // fit first to get accurate dimensions. If hidden (background reconnect),
        // use the active session's dimensions as a reasonable default rather than
        // the potentially-zero dimensions from a hidden container. (#312)
        if (session?.fitAddon) {
          const container = document.querySelector<HTMLElement>(`#terminal > [data-session-id="${sessionId}"]`);
          if (container && !container.classList.contains('hidden')) {
            session.fitAddon.fit();
          }
        }
        const cols = (session?.terminal?.cols && session.terminal.cols > 1) ? session.terminal.cols : 80;
        const rows = (session?.terminal?.rows && session.terminal.rows > 1) ? session.terminal.rows : 24;
        newWs.send(JSON.stringify({ type: 'resize', cols, rows }));
        // On first connect: collapse nav chrome and switch to terminal (#36).
        // On reconnect: leave the tab bar as-is so user isn't interrupted.
        if (!appState.hasConnected) {
          appState.hasConnected = true;
          appState.tabBarVisible = false;
          _applyTabBarVisibility();
        }
        _focusIME();
        break;

      case 'output':
        _bufferTerminalWrite(sessionId, msg.data);
        if (appState.recording && appState.recordingStartTime !== null) {
          appState.recordingEvents.push([(Date.now() - appState.recordingStartTime) / 1000, 'o', msg.data]);
        }
        break;

      case 'error':
        if (session && isSessionConnected(session)) {
          // Already connected — transient error, don't interrupt with modal
          _toast(`Error: ${msg.message}`);
        } else {
          // Not yet connected — this is a connection failure, clean up
          _toast(`Connection failed: ${msg.message}`);
          closeSession(sessionId);
        }
        break;

      case 'disconnected':
        if (session && session.state === 'connected') transitionSession(sessionId, 'soft_disconnected');
        _setStatus('disconnected', 'Disconnected');
        if (!silent) _showConnectionStatus(`Disconnected: ${msg.reason ?? 'unknown reason'}`, { error: true });
        stopAndDownloadRecording(); // auto-save recording on SSH disconnect (#54)
        scheduleReconnect();
        break;

      // [SFTP_CLIENT_ROUTER] -- every type in SFTP_MSG must be listed here
      case 'sftp_ls_result':
      case 'sftp_error':
      case 'sftp_download_result':
      case 'sftp_download_meta':
      case 'sftp_download_chunk':
      case 'sftp_download_end':
      case 'sftp_upload_result':
      case 'sftp_upload_ack':
      case 'sftp_stat_result':
      case 'sftp_rename_result':
      case 'sftp_delete_result':
      case 'sftp_realpath_result':
        if (msg.type === 'sftp_upload_ack') _resolveAck(msg.requestId, msg.offset);
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
            currentSession()?.ws?.send(JSON.stringify({ type: 'hostkey_response', accepted }));
          });
        } else if (known.fingerprint === msg.fingerprint) {
          currentSession()?.ws?.send(JSON.stringify({ type: 'hostkey_response', accepted: true }));
        } else {
          _showHostKeyPrompt(msg, known.fingerprint, (accepted) => {
            if (accepted) {
              const updated = JSON.parse(localStorage.getItem('knownHosts') ?? '{}') as Record<string, KnownHost>;
              updated[hostKey] = { fingerprint: msg.fingerprint, keyType: msg.keyType, addedAt: new Date().toISOString() };
              localStorage.setItem('knownHosts', JSON.stringify(updated));
            }
            currentSession()?.ws?.send(JSON.stringify({ type: 'hostkey_response', accepted }));
          });
        }
        break;
      }
    }
  }, signal ? { signal } : undefined);

  newWs.addEventListener('close', (event: CloseEvent) => {
    // Capture before clearing — needed to distinguish "was connected" from "never connected"
    const wasSshConnected = session ? isSessionConnected(session) : false;
    if (session && session.state !== 'disconnected' && session.state !== 'closed' && session.state !== 'failed') {
      // From connecting/authenticating, transition to 'failed'; from connected/soft_disconnected to 'disconnected'
      const target = (session.state === 'connecting' || session.state === 'authenticating') ? 'failed' : 'disconnected';
      transitionSession(sessionId, target);
    }
    stopKeepAlive(sessionId);
    if (!session?.profile) return;

    _setStatus('disconnected', 'Disconnected');

    // If SSH never connected, this session is dead — clean up, don't reconnect
    if (!wasSshConnected && !openedThisAttempt) {
      _wsConsecFailures++;
      if (_wsConsecFailures >= WS_MAX_AUTH_FAILURES) {
        _wsConsecFailures = 0;
        _dismissConnectionStatus();
        showErrorDialog('Connection rejected repeatedly.\n\nYour session token may have expired — reload the page to get a fresh one.');
      }
      closeSession(sessionId);
      return;
    }

    if (!wasSshConnected) {
      // WS opened but SSH never connected (auth failure, timeout, etc.)
      closeSession(sessionId);
      return;
    }

    // SSH was previously connected — this is a network drop, try to reconnect
    _wsConsecFailures = 0;
    if (!event.wasClean) {
      if (document.visibilityState === 'visible') {
        _toast('Reconnecting…');
        _openWebSocket({ silent: true, sessionId });
      } else {
        scheduleReconnect();
      }
    }
  }, signal ? { signal } : undefined);

  newWs.addEventListener('error', () => {
    if (!silent) showErrorDialog('WebSocket error — check server URL in Settings.');
  }, signal ? { signal } : undefined);
}

export function scheduleReconnect(): void {
  const session = currentSession();
  if (!session?.profile) return;
  const sid = appState.activeSessionId ?? '';

  const delaySec = Math.round(session.reconnectDelay / 1000);
  _toast(`Reconnecting in ${String(delaySec)}s…`);
  _setStatus('connecting', `Reconnecting in ${String(delaySec)}s…`);

  session.reconnectTimer = setTimeout(() => {
    const s = appState.sessions.get(sid);
    if (s) {
      s.reconnectDelay = Math.min(
        s.reconnectDelay * RECONNECT.BACKOFF_FACTOR,
        RECONNECT.MAX_DELAY_MS
      );
    }
    _openWebSocket({ silent: true, sessionId: sid });
  }, session.reconnectDelay);
}

export function cancelReconnect(): void {
  const session = currentSession();
  if (session?.reconnectTimer) {
    clearTimeout(session.reconnectTimer);
    session.reconnectTimer = null;
  }
}

export function reconnect(): void {
  if (currentSession()?.profile) _openWebSocket();
}

// Application-layer keepalive (#29, #204): sends a ping every 25s so NAT/proxies
// don't drop idle SSH sessions. A dedicated Web Worker opens its own WS connection
// and sends pings directly -- Worker threads are not frozen when Chrome backgrounds
// the tab, unlike main-thread setInterval which gets throttled to ~60s.
// The main thread also sends pings as a belt-and-suspenders fallback.
const WS_PING_INTERVAL_MS = 25_000;

/** Exported for testing only. */
export function _startKeepAlive(sessionId: string): void { startKeepAlive(sessionId); }
/** Exported for testing only. */
export function _stopKeepAlive(sessionId: string): void { stopKeepAlive(sessionId); }

function startKeepAlive(sessionId: string): void {
  stopKeepAlive(sessionId);
  const session = appState.sessions.get(sessionId);
  if (!session) return;

  // Main-thread keepalive (throttled in background, but works when visible)
  session.keepAliveTimer = setInterval(() => {
    const ws = currentSession()?.ws;
    if (ws?.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'ping' }));
    } else {
      stopKeepAlive(sessionId);
    }
  }, WS_PING_INTERVAL_MS);

  // Worker keepalive: opens a separate WS that pings even when tab is frozen
  const wsUrl = session.ws?.url;
  if (!wsUrl) return;
  try {
    session.keepAliveWorker = new Worker('ws-keepalive-worker.js');
    session.keepAliveWorker.onmessage = () => {
      // Worker's WS disconnected -- not critical, main-thread ping is still running
    };
    session.keepAliveWorker.postMessage({ command: 'start', url: wsUrl, interval: WS_PING_INTERVAL_MS });
  } catch {
    // Worker unavailable -- main-thread setInterval is already running
  }
}

function stopKeepAlive(sessionId: string): void {
  const session = appState.sessions.get(sessionId);
  if (!session) return;
  if (session.keepAliveWorker) {
    session.keepAliveWorker.postMessage({ command: 'stop' });
    session.keepAliveWorker.terminate();
    session.keepAliveWorker = null;
  }
  if (session.keepAliveTimer) {
    clearInterval(session.keepAliveTimer);
    session.keepAliveTimer = null;
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

// Zombie WS probe: after resume, send a ping and wait for any WS activity.
// If nothing arrives within the timeout, the connection is dead — force-close
// and let the onclose handler trigger reconnect. (#153)
const ZOMBIE_PROBE_TIMEOUT_MS = 5000;
let _zombieProbeTimer: ReturnType<typeof setTimeout> | null = null;

/** Exported for testing. */
export function _probeZombieConnection(): void {
  const sessionWs = currentSession()?.ws;
  if (!sessionWs || sessionWs.readyState !== WebSocket.OPEN) return;

  // Send an application-layer ping to provoke a response or trigger a close
  sessionWs.send(JSON.stringify({ type: 'ping' }));

  // Wrap onmessage: any incoming data proves the connection is alive
  const ws = sessionWs;
  const origOnMessage = ws.onmessage;
  const cancelProbe = (): void => {
    if (_zombieProbeTimer) {
      clearTimeout(_zombieProbeTimer);
      _zombieProbeTimer = null;
    }
    ws.onmessage = origOnMessage;
  };

  ws.onmessage = function (this: WebSocket, event: MessageEvent) {
    cancelProbe();
    origOnMessage?.call(this, event);
  };

  _zombieProbeTimer = setTimeout(() => {
    _zombieProbeTimer = null;
    // Restore original handler before closing so onclose logic runs cleanly
    ws.onmessage = origOnMessage;
    ws.close();
  }, ZOMBIE_PROBE_TIMEOUT_MS);
}

// visibilitychange: reconnect ALL sessions that dropped while hidden,
// probe for zombie connections, and reacquire the wake lock. (#153)
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') {
    void acquireWakeLock();
    document.getElementById('errorDialogOverlay')?.classList.add('hidden');

    // Reconnect all dropped sessions, not just the active one
    const savedActiveId = appState.activeSessionId;
    let reconnected = false;
    for (const [sid, session] of appState.sessions) {
      if (!session.profile) continue;
      if (!session.ws || session.ws.readyState !== WebSocket.OPEN) {
        cancelReconnect();
        _openWebSocket({ silent: true, sessionId: sid });
        reconnected = true;
      } else {
        // WS is open — send a keepalive ping to keep the connection warm
        try { session.ws.send(JSON.stringify({ type: 'ping' })); } catch { /* ignore */ }
      }
    }
    if (reconnected) _toast('Reconnecting sessions…');
  } else {
    releaseWakeLock();
  }
});

export function disconnect(): void {
  stopAndDownloadRecording(); // auto-save any active recording (#54)
  cancelReconnect();
  if (appState.activeSessionId) stopKeepAlive(appState.activeSessionId);
  releaseWakeLock();
  const session = currentSession();
  if (session) {
    session.profile = null;
    if (session.ws) {
      session.ws.onclose = null;
      try { session.ws.send(JSON.stringify({ type: 'disconnect' })); } catch { /* may already be closed */ }
      session.ws.close();
      session.ws = null;
    }
    if (session.state !== 'disconnected' && session.state !== 'closed' && session.state !== 'failed') {
      const target = (session.state === 'connecting' || session.state === 'authenticating') ? 'failed' : 'disconnected';
      transitionSession(session.id, target);
    }
  }

  _setStatus('disconnected', 'Disconnected');
  _dismissConnectionStatus();
}

export function sendSSHInput(data: string): void {
  const session = currentSession();
  if (!session || !isSessionConnected(session) || !session.ws || session.ws.readyState !== WebSocket.OPEN) {
    if (session && !isSessionConnected(session)) {
      _toast('Session not connected — input dropped');
    }
    return;
  }
  session.ws.send(JSON.stringify({ type: 'input', data }));
}

// ── Connection status overlay (#172) ─────────────────────────────────────────

let _currentOverlay: HTMLDivElement | null = null;

function _showConnectionStatus(message: string, opts?: { error?: boolean }): void {
  // Reuse existing overlay — append message to scrollable log
  if (_currentOverlay) {
    const log = _currentOverlay.querySelector('.conn-status-log');
    if (log) {
      const line = document.createElement('div');
      line.className = opts?.error ? 'conn-status-message conn-status-error' : 'conn-status-message';
      line.textContent = message;
      log.appendChild(line);
      log.scrollTop = log.scrollHeight;
    }
    if (opts?.error) {
      const btn = _currentOverlay.querySelector('.conn-status-cancel');
      if (btn) btn.textContent = 'Close';
      _currentOverlay.classList.add('conn-status-failed');
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

  // Cancel button is always present — calls disconnect() for full cleanup (#105)
  const btn = document.createElement('button');
  btn.className = 'conn-status-cancel';
  btn.textContent = 'Cancel';
  btn.addEventListener('click', () => {
    disconnect();
    _dismissConnectionStatus();
  });
  dialog.appendChild(btn);

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
