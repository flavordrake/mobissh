/**
 * modules/connection.ts — WebSocket SSH connection lifecycle
 *
 * Manages WebSocket connection, SSH authentication, reconnect with
 * exponential backoff, keepalive pings, screen wake lock, host key
 * verification, and visibility-based reconnection.
 */

import type { ConnectionDeps, ConnectionStatus, ServerMessage, ConnectMessage, SSHProfile } from './types.js';
import { vaultLoad, vaultStore, tryUnlockVault } from './vault.js';
import { showErrorDialog, navigateToPanel, applySessionThemeIfVisible } from './ui.js';
import { saveRecentSession, getProfiles, getKeys } from './profiles.js';
import { getDefaultWsUrl, RECONNECT, escHtml, parseApprovalPayload } from './constants.js';
import { appState, currentSession, createSession, transitionSession, isSessionConnected, onStateChange } from './state.js';
import { logConnect } from './connect-log.js';
import { uploadDropTelemetry } from './drop-telemetry.js';
import { createSessionTerminal, setSessionHandleLookup } from './terminal.js';
import { SessionHandle } from './session.js';

// Sessions that should navigate to the terminal panel when SSH connects.
// Populated by _openWebSocket for user-initiated connections (not reconnects).
const _pendingNavigateSessions = new Set<string>();

// [SFTP_MSG] -- keep in sync with types.ts SERVER_MESSAGE sftp types and WS router below
type SftpMsg = Extract<ServerMessage, { type: 'sftp_ls_result' | 'sftp_error' | 'sftp_download_result' | 'sftp_download_meta' | 'sftp_download_chunk' | 'sftp_download_chunk_bin' | 'sftp_download_end' | 'sftp_upload_result' | 'sftp_upload_ack' | 'sftp_stat_result' | 'sftp_rename_result' | 'sftp_delete_result' | 'sftp_realpath_result' }>;
let _sftpHandler: ((msg: SftpMsg) => void) | null = null;
export function setSftpHandler(fn: (msg: SftpMsg) => void): void { _sftpHandler = fn; }

export const CHUNK_SIZE = 192 * 1024; // 192 KB per chunk

// Pending ack handlers: requestId -> { resolve, reject, timer }
// Rejection fires on WS close or per-ack timeout so the upload loop fails
// loudly instead of hanging forever on a stuck server (#478 simplify).
interface _AckHandler {
  resolve: (offset: number) => void;
  reject: (err: Error) => void;
  timer: ReturnType<typeof setTimeout>;
}
const _ackResolvers = new Map<string, _AckHandler>();

/** 30s ack timeout. Upload chunks should ack in <1s; longer means the server is
 *  unresponsive and we'd rather surface a failure than spin forever. */
const _ACK_TIMEOUT_MS = 30_000;

/** Fail every pending ack — called when the WS closes so uploads don't hang. */
export function _rejectAllPendingAcks(reason: string): void {
  for (const [rid, h] of _ackResolvers) {
    clearTimeout(h.timer);
    h.reject(new Error(reason));
    _ackResolvers.delete(rid);
  }
}

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

/** Wait for a server ack for the given requestId. Returns the acked offset.
 *  Rejects on WS close (via _rejectAllPendingAcks) or after _ACK_TIMEOUT_MS. */
function _waitForAck(requestId: string): Promise<number> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      _ackResolvers.delete(requestId);
      reject(new Error(`Upload ack timeout after ${String(_ACK_TIMEOUT_MS / 1000)}s`));
    }, _ACK_TIMEOUT_MS);
    _ackResolvers.set(requestId, { resolve, reject, timer });
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
  const h = _ackResolvers.get(requestId);
  if (h) {
    clearTimeout(h.timer);
    _ackResolvers.delete(requestId);
    h.reject(new Error('Upload cancelled'));
  }
  const session = currentSession();
  if (!session || !isSessionConnected(session) || !session.ws || session.ws.readyState !== WebSocket.OPEN) return;
  session.ws.send(JSON.stringify({ type: 'sftp_upload_cancel', requestId }));
}

/** Resolve a pending ack. Called from the WS message handler. */
export function _resolveAck(requestId: string, offset: number): void {
  const h = _ackResolvers.get(requestId);
  if (h) {
    clearTimeout(h.timer);
    _ackResolvers.delete(requestId);
    h.resolve(offset);
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
/** Start a chunked download. The server emits sftp_download_meta, then
 *  sftp_download_chunk (one per chunk, with offset), then sftp_download_end.
 *  Caller must buffer chunks and track progress — see #474. */
export function sendSftpDownloadStart(path: string, requestId: string): void {
  const session = currentSession();
  if (!session || !isSessionConnected(session) || !session.ws || session.ws.readyState !== WebSocket.OPEN) return;
  session.ws.send(JSON.stringify({ type: 'sftp_download_start', path, requestId }));
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

let _currentOverlay: HTMLDivElement | null = null;

interface KnownHost {
  fingerprint: string;
  keyType: string;
  addedAt: string;
}

// SessionHandle instances stored alongside SessionState for terminal lifecycle (#374)
const _sessionHandles = new Map<string, SessionHandle>();

/** Get the SessionHandle for a session (if created via SessionHandle). */
export function getSessionHandle(id: string): SessionHandle | undefined {
  return _sessionHandles.get(id);
}

/** Remove a SessionHandle (called on session close). */
export function removeSessionHandle(id: string): void {
  const handle = _sessionHandles.get(id);
  if (handle) {
    handle.close();
    _sessionHandles.delete(id);
  }
}
import { rebindSelectionWatcher } from './selection.js';
import { renderSessionList, closeSession } from './ui.js';
import { stopAndDownloadRecording } from './recording.js';
import { fireNotification } from './terminal.js';
import { probeConnectLayers } from './connect-probe.js';

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
  const buf = _writeBufs.get(sessionId) ?? '';
  if (!buf) return;
  _writeBufs.set(sessionId, '');

  // Route through SessionHandle.write() for visibility-aware buffering
  const handle = _sessionHandles.get(sessionId);
  if (handle) {
    handle.write(buf);
    return;
  }
  // Fallback for sessions without a handle
  const session = appState.sessions.get(sessionId);
  if (session?.terminal) {
    session.terminal.write(buf);
  }
}

function _bufferTerminalWrite(sessionId: string, data: string): void {
  _writeBufs.set(sessionId, (_writeBufs.get(sessionId) ?? '') + data);
  // Approval detection moved to WS message handler — hook POSTs to /api/approval,
  // server broadcasts as { type: 'approval_prompt' } to all clients.
  if (!_writeRafs.has(sessionId)) {
    _writeRafs.set(sessionId, requestAnimationFrame(() => { _flushTerminalWrite(sessionId); }));
  }
}
let _focusIME = (): void => {};
let _applyTabBarVisibility = (): void => {};

// Module-level so disconnect() can clear it (#388). Was previously local to _openWebSocket.
let _connectTimeout: ReturnType<typeof setTimeout> | null = null;

export function initConnection({ toast, setStatus, focusIME, applyTabBarVisibility }: ConnectionDeps): void {
  _toast = toast;
  _setStatus = setStatus;
  _focusIME = focusIME;
  _applyTabBarVisibility = applyTabBarVisibility;

  // Wire SessionHandle lookup into terminal.ts to avoid circular import (#374)
  setSessionHandleLookup((id) => _sessionHandles.get(id));
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

/**
 * Resolve the passphrase for an SSH key profile. Loads the key from vault if
 * needed, checks the in-memory cache, and prompts the user if necessary.
 * Returns 'ok' if the profile is ready to connect, 'cancelled' if the user
 * dismissed the prompt, or 'no-key' if the vault key could not be loaded.
 */
export async function _resolvePassphrase(profile: SSHProfile): Promise<'ok' | 'cancelled' | 'no-key'> {
  // Load key data from vault if not already present
  if (profile.authType === 'key' && profile.keyVaultId && !profile.privateKey) {
    const keyCreds = await vaultLoad(profile.keyVaultId);
    if (keyCreds?.data) {
      profile.privateKey = keyCreds.data as string;
    } else {
      return 'no-key';
    }
  }

  // If the key is encrypted and no passphrase is set, check cache/vault or prompt
  if (profile.authType === 'key' && profile.privateKey && _isKeyEncrypted(profile.privateKey) && !profile.passphrase) {
    const cacheKey = profile.keyVaultId ?? '';
    const cached = cacheKey ? _keyPassphraseCache.get(cacheKey) : undefined;
    if (cached !== undefined) {
      profile.passphrase = cached;
    } else {
      // Check vault for persisted passphrase before prompting
      if (cacheKey) {
        const stored = await vaultLoad(cacheKey);
        if (stored?.passphrase) {
          profile.passphrase = stored.passphrase as string;
          _keyPassphraseCache.set(cacheKey, stored.passphrase as string);
          return 'ok';
        }
      }

      const passphrase = await _promptPassphrase();
      if (passphrase === null) {
        return 'cancelled';
      }
      profile.passphrase = passphrase;
      if (cacheKey) {
        _keyPassphraseCache.set(cacheKey, passphrase);
        // Persist passphrase to vault alongside the key data
        const existing = await vaultLoad(cacheKey);
        if (existing) {
          existing.passphrase = passphrase;
          await vaultStore(cacheKey, existing);
        }
      }
    }
  }

  return 'ok';
}

// ── WebSocket / SSH connection ────────────────────────────────────────────────

// Max consecutive pre-open WS close events before halting the reconnect loop.
// A close before onopen fires typically indicates a server-side auth rejection.
// Bumped 3 → 5 (2026-04-29). With server readyTimeout now 30s, transient
// slow handshakes shouldn't halt — but real dead targets still hit the
// ceiling within a couple of minutes. Three strikes was too tight: a single
// slow visibility_resume cycle could halt all sessions simultaneously.
const WS_MAX_AUTH_FAILURES = 5;
// _wsConsecFailures is now per-session (SessionState._wsConsecFailures) — #362

/** Read the HMAC token injected by the server on page load (#93). */
function _getWsToken(): string {
  return document.querySelector<HTMLMetaElement>('meta[name="ws-token"]')?.content ?? '';
}

export async function connect(profile: SSHProfile): Promise<void> {
  // Resolve key data and passphrase (vault load + cache + prompt)
  const result = await _resolvePassphrase(profile);
  if (result === 'no-key') {
    _toast('Could not load stored key from vault.');
    return;
  }
  if (result === 'cancelled') {
    _toast('Connection cancelled.');
    return;
  }

  // Don't cancel other sessions' reconnect timers when creating a new session

  // Dedup: check for an existing session with the same profile (#391)
  let existingSessionId: string | null = null;
  for (const [sid, existing] of appState.sessions) {
    if (existing.profile
      && existing.profile.host === profile.host
      && existing.profile.port === (profile.port || 22)
      && existing.profile.username === profile.username) {
      existingSessionId = sid;
      break;
    }
  }

  // If a matching session exists, close it before creating the new one
  if (existingSessionId) {
    const oldHandle = _sessionHandles.get(existingSessionId);
    if (oldHandle) {
      oldHandle.hide();
      removeSessionHandle(existingSessionId);
    }
    const oldSession = appState.sessions.get(existingSessionId);
    if (oldSession) {
      transitionSession(existingSessionId, 'closed');
    }
  }

  // Create a SessionState entry for multi-session infrastructure (#59)
  const sessionId = `${profile.host}:${String(profile.port || 22)}:${profile.username}:${String(Date.now())}`;
  const session = createSession(sessionId);
  session.profile = profile;
  session.reconnectDelay = RECONNECT.INITIAL_DELAY_MS;
  appState.activeSessionId = sessionId;

  // Create SessionHandle for self-contained terminal lifecycle (#374)
  const handle = new SessionHandle(sessionId, profile);
  _sessionHandles.set(sessionId, handle);
  session.terminal = handle.terminal;
  session.fitAddon = handle.fitAddon;
  // Bridge: let handle send resize via the externally-managed WS
  handle.setExternalWsLookup(() => session.ws);

  // terminal.onData is registered in _openWebSocket as part of the connection cycle (#334)

  // Hide all other session containers, show the new one via SessionHandle (#374)
  for (const [sid, h] of _sessionHandles) {
    if (sid !== sessionId) h.hide();
  }
  handle.show();

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

  // Abort the previous connection cycle FIRST — removes all addEventListener
  // listeners via signal before we close the WS, preventing race conditions
  // where the old onclose handler fires and triggers a duplicate reconnect.
  if (session?._cycle) {
    session._cycle.controller.abort();
    for (const d of session._cycle.disposables) d.dispose();
    session._cycle = null;
  }
  if (session?.ws) {
    session.ws.close();
    session.ws = null;
  }

  const baseUrl = localStorage.getItem('wsUrl') ?? getDefaultWsUrl();
  const token = _getWsToken();
  const wsUrl = token ? `${baseUrl}?token=${encodeURIComponent(token)}` : baseUrl;

  _setStatus('connecting', `Connecting to ${baseUrl}…`);
  if (_connectTimeout) { clearTimeout(_connectTimeout); _connectTimeout = null; }

  let newWs: WebSocket;

  try {
    newWs = new WebSocket(wsUrl);
    // Use ArrayBuffer for binary frames (sftp_download_chunk_bin payloads).
    // Default is Blob; ArrayBuffer is synchronous and cheaper for our hot path.
    newWs.binaryType = 'arraybuffer';
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    _showConnectionStatus(`WebSocket error: ${message}`, { error: true, sessionId });
    // Schedule reconnect for THIS session, not whichever happens to be active.
    scheduleReconnect(sessionId);
    return;
  }

  // Happy path never shows the overlay: the WS opens in a few hundred ms and
  // _dismissConnectionStatus is called from the onopen/onconnected handlers.
  // Slow path: after 5s, show the overlay AND run the layered probe so the
  // user can tell which layer is blocking (radio / HTTP / WebSocket handshake).
  if (!silent) {
    const probeWs = newWs; // capture so the closure inspects *this* attempt
    _connectTimeout = setTimeout(() => {
      _connectTimeout = null;
      _showConnectionStatus(`Connecting to ${baseUrl}…`, { sessionId });
      _showConnectionStatus('Running diagnostic…');
      logConnect('diag_start', sessionId, {
        onLine: typeof navigator !== 'undefined' ? navigator.onLine : true,
        baseUrl,
      });
      void probeConnectLayers({
        onLine: typeof navigator !== 'undefined' ? navigator.onLine : true,
        fetchImpl: (url, init) => fetch(url, init),
        ws: probeWs,
      }).then((lines) => {
        for (const line of lines) {
          _showConnectionStatus(`[${line.layer}] ${line.message}`, { error: !line.ok });
          logConnect('diag_result', sessionId, {
            layer: line.layer,
            ok: line.ok,
            message: line.message,
          });
        }
      }).catch((err: unknown) => {
        const msg = err instanceof Error ? err.message : String(err);
        logConnect('diag_result', sessionId, { error: msg });
        _showConnectionStatus(`Diagnostic failed: ${msg}`, { error: true });
      });
    }, 5000);
  }

  // Transition BEFORE assigning session.ws so the 'connecting'/'reconnecting'
  // side-effects clean up the OLD WS (or no-op if null), not the new one (#331).
  if (session) {
    if (session.state === 'idle') transitionSession(sessionId, 'connecting');
    else if (session.state === 'soft_disconnected' || session.state === 'disconnected' || session.state === 'failed') {
      transitionSession(sessionId, 'reconnecting');
    }
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
    session._onDataDisposable = onDataDisp;
    session._cycle?.disposables.push(onDataDisp);
  }

  newWs.addEventListener('open', () => {
    logConnect('ws_open', sessionId, { host: session?.profile?.host, silent });
    // Don't reset _wsConsecFailures here — WS opens fine even when SSH host
    // is unreachable. Only reset on successful SSH ready (case 'ready' below).
    startKeepAlive(sessionId);
    const profile = session?.profile;
    if (!profile) return;

    // Resolve passphrase before building auth message (#418).
    // On reconnect, the in-memory cache may be empty (e.g. after page reload),
    // so we must re-resolve from vault/cache/prompt before sending credentials.
    void _resolvePassphrase(profile).then((result) => {
      if (result !== 'ok') {
        // User cancelled or vault unavailable — close WS, don't send credentials
        newWs.close();
        if (result === 'cancelled') _toast('Reconnect cancelled — passphrase required.');
        else _toast('Could not load stored key from vault.');
        return;
      }

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
      if (!silent && _currentOverlay) _showConnectionStatus(`SSH → ${profile.title || `${profile.username}@${profile.host}:${String(profile.port || 22)}`}…`);
    });
  }, signal ? { signal } : undefined);

  // Pending binary-header: when a sftp_download_chunk_bin text message arrives,
  // the *next* binary frame on this WS carries its payload. Message order on
  // a single WS is preserved so the pairing is race-free.
  let pendingBinHeader: { requestId: string; offset: number; size: number } | null = null;

  newWs.addEventListener('message', (event: MessageEvent) => {
    // Binary frame path: consume bytes with the last-seen binary header.
    if (event.data instanceof ArrayBuffer) {
      if (!pendingBinHeader) return;
      const header = pendingBinHeader;
      pendingBinHeader = null;
      // Forward as a pseudo-message that carries bytes via a hidden payload field
      // on a sftp_download_chunk-shaped record. ui.ts reads payload when present.
      const binMsg = {
        type: 'sftp_download_chunk',
        requestId: header.requestId,
        offset: header.offset,
        data: '',
        payload: new Uint8Array(event.data),
      } as unknown as ServerMessage;
      _sftpHandler?.(binMsg as SftpMsg);
      return;
    }

    let msg: ServerMessage;
    try { msg = JSON.parse(event.data as string) as ServerMessage; } catch { return; }

    switch (msg.type) {
      case 'connected': {
        logConnect('ssh_ready', sessionId, { host: session?.profile?.host });
        // If this is a recovery (we were in `reconnecting` not `connecting`),
        // upload the last 24h of telemetry so we can see what happened
        // without waiting for the user to file a bug report. Throttled to
        // 5 min/upload — a tight reconnect loop won't flood the server.
        const wasRecovering = session?.state === 'reconnecting';
        if (session) {
          session._wsConsecFailures = 0;
          session.reconnectDelay = RECONNECT.INITIAL_DELAY_MS;
          if (session.state === 'connecting' || session.state === 'reconnecting') transitionSession(sessionId, 'authenticating');
          if (session.state === 'authenticating') transitionSession(sessionId, 'connected');
        }
        if (wasRecovering) {
          // session is non-null here because wasRecovering was derived from
          // session?.state === 'reconnecting', which only narrows true when
          // session exists. TS' flow analysis carries that narrowing forward.
          uploadDropTelemetry('recovered', sessionId, session.profile?.host);
        }
        void acquireWakeLock();
        // Mouse tracking reset removed — xterm.js starts clean, and writing mode
        // disables here leaks through onData → SSH → echo. If stale mouse tracking
        // is an issue (#81), the fix should be server-side or via a dedicated
        // reset-modes message, not terminal.write/reset.
        // Chrome status reflects the session the USER is viewing. Inactive
        // session reaching ssh_ready shouldn't repaint the foreground header.
        if (session?.profile && sessionId === appState.activeSessionId) {
          _setStatus('connected', session.profile.title || `${session.profile.username}@${session.profile.host}`);
        }
        // Cancel the 5s timeout if it hasn't fired yet
        if (_connectTimeout) { clearTimeout(_connectTimeout); _connectTimeout = null; }
        // Dismiss any visible overlay only if it belongs to this session.
        // (The overlay shows for user-initiated connects and tracks one
        // session at a time via _showConnectionStatus's sessionId arg.)
        if (sessionId === appState.activeSessionId) _dismissConnectionStatus();
        // Apply the session's theme — but only if the user is looking at
        // a session-bound panel. Background reconnects / approval events
        // shouldn't repaint Settings or Connect. (#364 / theme-in-settings)
        if (session) applySessionThemeIfVisible(session);
        // Navigate to terminal now that SSH is established (#309).
        // Only for user-initiated connections — reconnects don't navigate.
        // navigateToPanel triggers fit() on the active session, giving it
        // real container dimensions before we send resize to the server.
        if (_pendingNavigateSessions.delete(sessionId)) {
          navigateToPanel('terminal');
        }
        // Send terminal dimensions to server — after navigateToPanel so
        // the session has been fitted to real layout dimensions (#374)
        const connHandle = _sessionHandles.get(sessionId);
        const cols = connHandle ? connHandle.terminal.cols : (session?.terminal?.cols && session.terminal.cols > 1) ? session.terminal.cols : 80;
        const rows = connHandle ? connHandle.terminal.rows : (session?.terminal?.rows && session.terminal.rows > 1) ? session.terminal.rows : 24;
        newWs.send(JSON.stringify({ type: 'resize', cols, rows }));
        // On first connect: collapse nav chrome and switch to terminal (#36).
        // On reconnect: leave the tab bar as-is so user isn't interrupted.
        if (!appState.hasConnected) {
          appState.hasConnected = true;
          appState.tabBarVisible = false;
          _applyTabBarVisibility();
        }
        // Save to recent sessions for cold-start reconnect (#385)
        if (session?.profile) {
          const profiles = getProfiles();
          const profileIdx = profiles.findIndex(
            (p) => p.host === session.profile!.host
              && String(p.port || 22) === String(session.profile!.port || 22)
              && p.username === session.profile!.username
          );
          if (profileIdx >= 0) {
            saveRecentSession(session.profile, profileIdx);
          }
        }
        _focusIME();
        break;
      }

      case 'output':
        _bufferTerminalWrite(sessionId, msg.data);
        if (appState.recording && appState.recordingStartTime !== null) {
          appState.recordingEvents.push([(Date.now() - appState.recordingStartTime) / 1000, 'o', msg.data]);
        }
        break;

      case 'error':
        logConnect('ssh_error', sessionId, {
          message: msg.message,
          host: session?.profile?.host,
          sessionState: session?.state,
        });
        if (session && isSessionConnected(session)) {
          // Already connected — transient error, don't interrupt with modal.
          // Only toast the active session; backgrounded session errors stay
          // in the per-session state machine (visible via the session bar).
          if (sessionId === appState.activeSessionId) _toast(`Error: ${msg.message}`);
        } else {
          // Not yet connected — SSH-level failure (e.g. handshake timeout).
          // Don't reconnect here — let the WS onclose handler manage retries
          // with its failure counter to prevent infinite loops to dead hosts.
          console.log(`[error-msg] SSH error pre-connect: ${msg.message}, letting onclose handle retry`);
          if (sessionId === appState.activeSessionId) _toast(`Connection failed: ${msg.message}`);
          if (!session?.profile) {
            closeSession(sessionId);
          }
        }
        break;

      case 'disconnected': {
        logConnect('ssh_disconnected', sessionId, {
          reason: msg.reason,
          host: session?.profile?.host,
        });
        // Capture the prior state BEFORE transitioning. We only toast/flag
        // the user when a previously-WORKING session disconnects (i.e. they
        // notice their session went down). Reconnect-attempt failures
        // (state === 'reconnecting' / 'failed' / mid-handshake) are part of
        // the existing reconnect cycle the user already knows about — the
        // session bar shows the spinner; toasting "Disconnected: handshake
        // timeout" every retry is just noise when the terminal still looks
        // fine to the user.
        const wasUserVisibleConnected = session?.state === 'connected';
        if (wasUserVisibleConnected) transitionSession(sessionId, 'soft_disconnected');
        if (sessionId === appState.activeSessionId && wasUserVisibleConnected) {
          _setStatus('disconnected', 'Disconnected');
          // Toast instead of blocking overlay — the session will auto-reconnect (#351)
          _toast(`Disconnected: ${msg.reason ?? 'connection lost'}`);
        }
        stopAndDownloadRecording(); // auto-save recording on SSH disconnect (#54)
        // Reconnect THIS session, not whichever is active in the UI — otherwise
        // a disconnect on a backgrounded session reconnect-thrashes the
        // foreground one (observed: 2026-04-28 connect log, healthy spark
        // session getting redundant ws_open events after another session's
        // ssh_disconnected fired).
        scheduleReconnect(sessionId);
        break;
      }

      // [SFTP_CLIENT_ROUTER] -- every type in SFTP_MSG must be listed here
      case 'sftp_download_chunk_bin':
        // Stash the header; the next binary WS frame on this connection carries
        // its payload. Per-WS message order is preserved so pairing is safe.
        pendingBinHeader = { requestId: msg.requestId, offset: msg.offset, size: msg.size };
        break;
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
        // Reject any pending ack tied to this requestId — upload loop throws
        // instead of spinning after a server-side SFTP failure.
        if (msg.type === 'sftp_error') {
          const h = _ackResolvers.get(msg.requestId);
          if (h) {
            clearTimeout(h.timer);
            _ackResolvers.delete(msg.requestId);
            h.reject(new Error(msg.message));
          }
        }
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

      case 'approval_prompt': {
        // WS fallback for approvals — SSE is primary but may be disconnected
        const raw = msg as unknown as Record<string, unknown>;
        const ap = parseApprovalPayload(raw);
        console.log('[hook→ws] approval_prompt:', ap.label);
        window.dispatchEvent(new CustomEvent('approval-prompt', {
          detail: {
            phase: 'ready',
            sessionId,
            requestId: ap.requestId,
            tool: ap.toolName,
            detail: ap.command,
            description: ap.label,
            source: ap.source,
            options: [{ key: '1', label: 'Yes' }, { key: '2', label: 'No' }],
          },
        }));
        break;
      }

      case 'hook_event': {
        // All non-approval hook events — log to debug overlay + notify when backgrounded
        const hookMsg = msg as unknown as { event?: string; tool?: string; detail?: string; description?: string; hookHost?: string };
        console.log('[hook→ws]', hookMsg.event, hookMsg.tool, hookMsg.detail);

        // Fire PWA notification for significant events when app is backgrounded.
        // Unlike terminal bell notifications, hook events bypass the termNotifications
        // setting — they're infrastructure events, always worth knowing about.
        const event = hookMsg.event ?? '';
        const isSignificant = event === 'SubagentStart' || event === 'commit' || event === 'push'
          || event === 'deploy' || event === 'pr-create' || event === 'integrate';
        const isBackgrounded = !document.hasFocus() || document.visibilityState === 'hidden';
        if (isSignificant && isBackgrounded && Notification.permission === 'granted') {
          const title = `MobiSSH: ${event}`;
          const body = [hookMsg.tool, hookMsg.detail, hookMsg.description].filter(Boolean).join(' — ');
          // Prefer hookHost from the payload; fall back to the WS session's host
          // (since the hook event arrived on this session's WS).
          const hookHost = hookMsg.hookHost ?? session?.profile?.host;
          fireNotification(title, body || event, hookHost ? { hookHost } : undefined);
        }
        break;
      }
    }
  }, signal ? { signal } : undefined);

  newWs.addEventListener('close', (event: CloseEvent) => {
    logConnect('ws_close', sessionId, {
      code: event.code,
      reason: event.reason,
      wasClean: event.wasClean,
      host: session?.profile?.host,
      sessionState: session?.state,
      failures: session?._wsConsecFailures,
    });
    // Fail any in-flight upload acks immediately so uploadFileChunked throws
    // instead of hanging forever on a WS that's gone.
    _rejectAllPendingAcks('WebSocket closed');
    // Capture BEFORE transition — needed to distinguish "was connected" from "never connected"
    const wasSshConnected = session ? (session.state === 'connected' || session.state === 'soft_disconnected') : false;
    if (session && session.state !== 'disconnected' && session.state !== 'closed' && session.state !== 'failed') {
      // Map current state → next state for the close event:
      //   connected / soft_disconnected → disconnected (was working, lost it)
      //   connecting / authenticating / reconnecting → failed (in-flight, didn't make it)
      // `reconnecting → disconnected` is NOT a valid VALID_TRANSITIONS entry
      // and the throw silently swallowed the rest of this handler — including
      // `scheduleReconnect(sessionId)` below — leaving the session wedged in
      // `reconnecting` state with no pending timer. Only visibility_resume
      // kicks could revive it. Bug-for-bug parallel to the disconnect()
      // throw fixed in b1bc871; same predicate, same omission.
      const target = (session.state === 'connecting'
        || session.state === 'authenticating'
        || session.state === 'reconnecting') ? 'failed' : 'disconnected';
      transitionSession(sessionId, target);
    }
    stopKeepAlive(sessionId);
    if (!session?.profile) return;

    // Only update chrome status for the active session.
    if (sessionId === appState.activeSessionId) {
      _setStatus('disconnected', 'Disconnected');
    }

    // All reconnect attempts go through scheduleReconnect which has its own
    // failure counter. Previously-connected sessions get a first free reconnect,
    // then the counter applies to prevent infinite loops to dead hosts.
    console.log(`[onclose] session=${sessionId} wasSsh=${String(wasSshConnected)} failures=${String(session._wsConsecFailures)} state=${session.state} code=${String(event.code)} reason=${event.reason}`);
    // Server rejected the upgrade due to rate-limit or concurrency cap (1008).
    // Back off hard — retrying immediately just compounds the cap pressure and
    // drops the user into a spinning-reconnect loop across every session.
    if (event.code === 1008) {
      if (sessionId === appState.activeSessionId) {
        _toast(`Server busy: ${event.reason || 'too many connections'} — slowing reconnect`);
      }
      session.reconnectDelay = Math.min(session.reconnectDelay * 2, RECONNECT.MAX_DELAY_MS);
    } else if (wasSshConnected && sessionId === appState.activeSessionId) {
      _toast('Reconnecting…');
    }
    scheduleReconnect(sessionId);
  }, signal ? { signal } : undefined);

  newWs.addEventListener('error', () => {
    logConnect('ws_error', sessionId, {
      host: session?.profile?.host,
      readyState: newWs.readyState,
      silent,
    });
    if (!silent) {
      disconnect(sessionId);
      const diag = session?.profile ? `\n\n${_connectionDiagnostic(session.profile)}` : '';
      showErrorDialog(`WebSocket error — check server URL in Settings.${diag}`);
    }
  }, signal ? { signal } : undefined);
}

/** Build a short diagnostic block for connection error dialogs/toasts.
 *  Includes target (user@host:port), auth type, and key name when applicable. */
function _connectionDiagnostic(profile: SSHProfile): string {
  const lines: string[] = [];
  const port = profile.port || 22;
  lines.push(`Target: ${profile.username}@${profile.host}:${String(port)}`);
  if (profile.authType === 'password') {
    lines.push('Auth: password');
  } else if (profile.keyVaultId) {
    const key = getKeys().find((k) => k.vaultId === profile.keyVaultId);
    lines.push(`Auth: key (${key?.name ?? 'unknown key'})`);
  } else {
    lines.push('Auth: key (inline)');
  }
  return lines.join('\n');
}

export function scheduleReconnect(sessionId?: string): void {
  const sid = sessionId ?? appState.activeSessionId ?? '';
  const session = appState.sessions.get(sid);
  if (!session?.profile) return;

  // Guard: stop reconnecting after repeated failures to unreachable hosts
  const wasConnected = session.state === 'connected' || session.state === 'soft_disconnected';
  if (!wasConnected) {
    session._wsConsecFailures++;
    console.log(`[scheduleReconnect] sid=${sid} failures=${String(session._wsConsecFailures)}/${String(WS_MAX_AUTH_FAILURES)} state=${session.state}`);
    if (session._wsConsecFailures >= WS_MAX_AUTH_FAILURES) {
      logConnect('reconnect_halt', sid, {
        host: session.profile.host,
        failures: WS_MAX_AUTH_FAILURES,
      });
      console.log(`[scheduleReconnect] HALT — giving up on session=${sid}`);
      session._wsConsecFailures = 0;
      transitionSession(sid, 'failed');
      _dismissConnectionStatus();
      // Only modal-block when the user is actively viewing the failing session.
      // Otherwise the user gets a "host unreachable" dialog over a healthy
      // session they're working in — observed 2026-04-28 when spark halted
      // while user was using nv-dev. Backgrounded session failures should
      // be communicated non-blockingly via the session bar's failed state +
      // a toast.
      const isActive = sid === appState.activeSessionId;
      const hostLabel = session.profile.host;
      if (isActive) {
        showErrorDialog(`Host unreachable after ${String(WS_MAX_AUTH_FAILURES)} attempts.\n\n${_connectionDiagnostic(session.profile)}\n\nThe remote host did not respond. Check that it is online, then tap Connect to retry.`);
      } else {
        _toast(`${hostLabel}: unreachable — tap session to retry`);
      }
      return;
    }
  }

  const delaySec = Math.round(session.reconnectDelay / 1000);
  logConnect('reconnect_scheduled', sid, {
    host: session.profile.host,
    delayMs: session.reconnectDelay,
    failures: session._wsConsecFailures,
    wasConnected,
  });
  // Only toast / set chrome status for the session the user is looking at.
  // Backgrounded sessions reconnect silently — their state shows in the
  // session bar, no need to spam the foreground.
  if (sid === appState.activeSessionId) {
    _toast(`Reconnecting in ${String(delaySec)}s…`);
    _setStatus('connecting', `Reconnecting in ${String(delaySec)}s…`);
  }

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

export function cancelReconnect(sessionId?: string): void {
  const sid = sessionId ?? appState.activeSessionId ?? '';
  const session = appState.sessions.get(sid);
  if (session?.reconnectTimer) {
    clearTimeout(session.reconnectTimer);
    session.reconnectTimer = null;
  }
}

// Per-session reconnect transaction tracking (#362)
const _reconnectInFlight = new Map<string, Promise<string>>();

/**
 * Reconnect a session. Returns a promise that resolves with the outcome state.
 * If a reconnect is already in flight for this session, returns the existing
 * promise — callers get the same result without creating duplicate connections.
 * Timeout: 30s. On timeout, resolves with 'timeout' but doesn't cancel the attempt.
 */
export function reconnect(sessionId?: string): Promise<string> {
  const sid = sessionId ?? appState.activeSessionId ?? '';
  const session = appState.sessions.get(sid);
  if (!session?.profile) return Promise.resolve('no-profile');
  if (session.state === 'connected') return Promise.resolve('connected');

  // If a reconnect is already in flight, join it instead of creating a new one
  const existing = _reconnectInFlight.get(sid);
  if (existing) return existing;

  // Start the reconnect
  _openWebSocket({ sessionId: sid });

  // Create a promise that resolves when the session reaches a terminal state
  const txn = new Promise<string>((resolve) => {
    const timer = setTimeout(() => {
      _reconnectInFlight.delete(sid);
      resolve('timeout');
    }, 30000);

    onStateChange((s, newState) => {
      if (s.id !== sid) return;
      if (newState === 'connected' || newState === 'failed' || newState === 'disconnected' || newState === 'closed') {
        clearTimeout(timer);
        _reconnectInFlight.delete(sid);
        resolve(newState);
      }
    });
  });

  _reconnectInFlight.set(sid, txn);
  return txn;
}

// Application-layer keepalive (#29): sends a ping every 25s so NAT/proxies
// don't drop idle SSH sessions.
//
// History: #204 originally added a SECOND WebSocket per session via a Web
// Worker, on the theory that workers are not frozen when Chrome backgrounds
// the tab. In practice that doubled bridge load (4 sessions = 8 WSes from
// the phone, with `active: 7` regularly observed in bridge logs) and DID
// NOT keep the main SSH WS alive — Android tears down WSes at the OS level
// regardless of what a worker pings, because the worker's WS isn't the same
// socket carrying the SSH session. Removed the worker; main-thread ping is
// the only keepalive now. The actual "keep tab alive when backgrounded"
// fix is the foreground notification (Settings → Keep alive in background).
const WS_PING_INTERVAL_MS = 25_000;

/** Exported for testing only. */
export function _startKeepAlive(sessionId: string): void { startKeepAlive(sessionId); }
/** Exported for testing only. */
export function _stopKeepAlive(sessionId: string): void { stopKeepAlive(sessionId); }

function startKeepAlive(sessionId: string): void {
  stopKeepAlive(sessionId);
  const session = appState.sessions.get(sessionId);
  if (!session) return;

  // Main-thread keepalive — ping THIS session's WS, not currentSession() (#362)
  session.keepAliveTimer = setInterval(() => {
    const s = appState.sessions.get(sessionId);
    if (s?.ws?.readyState === WebSocket.OPEN) {
      s.ws.send(JSON.stringify({ type: 'ping' }));
    } else {
      stopKeepAlive(sessionId);
    }
  }, WS_PING_INTERVAL_MS);
}

function stopKeepAlive(sessionId: string): void {
  const session = appState.sessions.get(sessionId);
  if (!session) return;
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
// and let the onclose handler trigger reconnect. (#153, #354)
const ZOMBIE_PROBE_TIMEOUT_MS = 5000;
const _zombieProbeTimers = new Map<string, ReturnType<typeof setTimeout>>();

/** Exported for testing. Probes ALL sessions with open WS, not just current. */
/** Probe a single session's WS — force-close if no response within timeout. */
export function probeSession(sid: string): void {
  const session = appState.sessions.get(sid);
  if (!session?.profile) return;
  const sessionWs = session.ws;
  if (!sessionWs || sessionWs.readyState !== WebSocket.OPEN) return;
  // Already being probed
  if (_zombieProbeTimers.has(sid)) return;

  sessionWs.send(JSON.stringify({ type: 'ping' }));

  const ws = sessionWs;
  const origOnMessage = ws.onmessage;
  const cancelProbe = (): void => {
    const timer = _zombieProbeTimers.get(sid);
    if (timer) {
      clearTimeout(timer);
      _zombieProbeTimers.delete(sid);
    }
    ws.onmessage = origOnMessage;
  };

  ws.onmessage = function (this: WebSocket, event: MessageEvent) {
    cancelProbe();
    origOnMessage?.call(this, event);
  };

  _zombieProbeTimers.set(sid, setTimeout(() => {
    _zombieProbeTimers.delete(sid);
    ws.onmessage = origOnMessage;
    ws.close();
  }, ZOMBIE_PROBE_TIMEOUT_MS));
}

/** Probe all sessions with open WS — force-close unresponsive ones. */
export function _probeZombieConnection(): void {
  for (const [sid] of appState.sessions) {
    probeSession(sid);
  }
}

// visibilitychange: reconnect ALL sessions that dropped while hidden,
// probe for zombie connections, and reacquire the wake lock. (#153)
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') {
    logConnect('visibility_resume', undefined, { onLine: navigator.onLine });
    void acquireWakeLock();
    document.getElementById('errorDialogOverlay')?.classList.add('hidden');

    // Pre-warm the TCP+TLS connection to the bridge BEFORE any WS attempt.
    // Observed (2026-04-29 19:42 telemetry): on a cold mobile radio after
    // backgrounding, the FIRST ws_open takes ~7.5s end-to-end (radio wake +
    // TCP SYN + TLS handshake + WS upgrade). Subsequent WSes only take
    // ~5s because they share the warm TCP/TLS path.
    //
    // Firing fetch('/version') as fire-and-forget warms that path while
    // the rest of the resume handler runs. By the time _openWebSocket()
    // creates the WS, the TLS connection is already established and the WS
    // upgrade is one extra round-trip instead of four. {keepalive:true}
    // ensures the request survives if the JS context flickers.
    try {
      void fetch('version', { keepalive: true, cache: 'no-store' }).catch(() => {});
    } catch { /* fetch unavailable — harmless */ }

    // Auto-unlock vault on resume if biometric is enrolled — avoids password
    // prompt on every reconnect after the idle timer locked the vault.
    if (!appState.vaultKey) {
      void tryUnlockVault('silent').catch(() => {});
    }

    // Reconnect all dropped sessions — active first, others staggered (#354).
    // Non-active sessions get a 3s delay so Tailscale tunnels have time to
    // re-establish after the phone comes back online.
    //
    // SKIP `failed` sessions: they hit the 3-strike halt and need an
    // explicit user retry OR a real network change (online event). Without
    // this guard, visibility_resume cycled the user through repeated
    // 10s SSH handshake timeouts on every screen-on event — the
    // close-and-restart-fixes-it loop the user reported.
    // Stale-in-flight threshold. Android Chrome aggressively throttles
    // background JS, so a `reconnecting` session whose timer fired during
    // suspension can sit in that state forever. After this much wall-clock
    // time without progress, treat it as dead and force a fresh attempt
    // even though the state machine still says "in flight". 20s is well
    // past the SSH 10s readyTimeout — anything older is definitely stuck.
    const STALE_INFLIGHT_MS = 20_000;
    const now = Date.now();
    let reconnected = false;
    const activeId = appState.activeSessionId ?? '';
    for (const [sid, session] of appState.sessions) {
      if (!session.profile) continue;
      // `failed` is the user-must-retry gate; never auto-disturb.
      if (session.state === 'failed') continue;

      const inFlight = session.state === 'connecting'
        || session.state === 'authenticating'
        || session.state === 'reconnecting';
      const stateAge = now - session._stateChangedAt;
      // Healthy in-flight: leave alone. Stuck in-flight (age > threshold):
      // close the stale WS and start fresh. Disconnected/closed: also reopen.
      if (inFlight && stateAge < STALE_INFLIGHT_MS) continue;

      // A WS in state CONNECTING means a reconnect is already in flight (a
      // pending reconnectTimer fired moments before this visibility handler
      // ran — common after a brief background, when queued timers fire ahead
      // of the visibility event). Treating CONNECTING as "dead" here causes a
      // duplicate reconnect that races the in-flight one and stacks SSH
      // handshakes on the bridge. Only force a fresh reconnect when the WS
      // is unambiguously dead (null / CLOSING / CLOSED) or the in-flight
      // state has aged past the stale threshold.
      const wsDead = !session.ws
        || session.ws.readyState === WebSocket.CLOSING
        || session.ws.readyState === WebSocket.CLOSED;
      if (wsDead || (inFlight && stateAge >= STALE_INFLIGHT_MS)) {
        cancelReconnect(sid);
        if (sid === activeId) {
          _openWebSocket({ silent: true, sessionId: sid });
        } else {
          // Was 3000ms — the original comment said "Tailscale tunnels have
          // time to re-establish", but with the prewarm above the TCP/TLS
          // path is already warm by the time non-active sessions fire. 500ms
          // gives the active session a tiny head-start on the WS upgrade so
          // it gets the user's foreground-priority handshake, then the
          // others follow on the now-multiplexed connection.
          setTimeout(() => { _openWebSocket({ silent: true, sessionId: sid }); }, 500);
        }
        reconnected = true;
      }
    }
    if (reconnected) _toast('Reconnecting sessions…');

    // Probe all sessions with open WS for zombie connections (#354)
    _probeZombieConnection();

    // No automatic fit on visibility restore — terminal stays at its current
    // layout size. Output buffered while hidden replays on next show().
  } else {
    logConnect('visibility_hide', undefined, { onLine: navigator.onLine });
    releaseWakeLock();
  }
});

// Network online/offline events — critical signal when user moves between
// wifi/cell on mobile. Both fire on the window object.
//
// On `online`, give every `failed` session one shot to recover. This is the
// genuine "network came back" event (not just visibility), so it deserves a
// retry even after the 3-strike halt. The user no longer needs to kill the
// app to escape the failed-after-network-change loop.
window.addEventListener('online', () => {
  logConnect('net_online', undefined, {});
  for (const [sid, session] of appState.sessions) {
    if (session.state !== 'failed' || !session.profile) continue;
    session._wsConsecFailures = 0;
    session.reconnectDelay = RECONNECT.INITIAL_DELAY_MS;
    transitionSession(sid, 'reconnecting');
    cancelReconnect(sid);
    _openWebSocket({ silent: true, sessionId: sid });
  }
});
window.addEventListener('offline', () => {
  logConnect('net_offline', undefined, {});
});

export function disconnect(sessionId?: string): void {
  const sid = sessionId ?? appState.activeSessionId ?? '';
  const session = appState.sessions.get(sid);
  stopAndDownloadRecording(); // auto-save any active recording (#54)
  cancelReconnect(sid);
  stopKeepAlive(sid);
  releaseWakeLock();
  // Clear pending connect timeout so overlay doesn't reappear after cancel (#388)
  if (_connectTimeout) { clearTimeout(_connectTimeout); _connectTimeout = null; }
  if (session) {
    // Abort the cycle FIRST — removes all signal-bound listeners so the close
    // handler doesn't fire and trigger a reconnect loop (#388)
    if (session._cycle) {
      session._cycle.controller.abort();
      for (const d of session._cycle.disposables) d.dispose();
      session._cycle = null;
    }
    if (session.ws) {
      session.ws.onclose = null;
      try { session.ws.send(JSON.stringify({ type: 'disconnect' })); } catch { /* may already be closed */ }
      session.ws.close();
      session.ws = null;
    }
    // Transition state BEFORE nulling profile so side-effects can read it (#388)
    // `reconnecting` was previously routed to `disconnected`, but
    // `reconnecting → disconnected` is NOT a valid state-machine transition
    // (only authenticating / connected / failed / closed). The throw left
    // the rest of disconnect() unrun and closeSession() un-called — so the
    // disconnect button silently did nothing on stuck-reconnecting sessions.
    // Route `reconnecting` to `failed` (which IS valid) along with the
    // other in-flight states.
    if (session.state !== 'disconnected' && session.state !== 'closed' && session.state !== 'failed') {
      const target = (session.state === 'connecting'
        || session.state === 'authenticating'
        || session.state === 'reconnecting') ? 'failed' : 'disconnected';
      transitionSession(session.id, target);
    }
    session.profile = null;
  }

  _setStatus('disconnected', 'Disconnected');
  _dismissConnectionStatus();
}

// Filter DA1/DA2/DA3 responses — xterm.js auto-responds to terminal capability
// queries from the remote (CSI c, CSI > c). If not filtered, responses leak
// through to the shell and appear as visible ?1;2c text (#350).
// eslint-disable-next-line no-control-regex
const DA_RESPONSE_RE = /\x1b\[\??[>]?[\d;]*c/g;

export function sendSSHInput(data: string): void {
  const session = currentSession();
  if (!session || !isSessionConnected(session) || !session.ws || session.ws.readyState !== WebSocket.OPEN) {
    if (session && !isSessionConnected(session)) {
      _toast('Session not connected — input dropped');
    }
    return;
  }
  const filtered = data.replace(DA_RESPONSE_RE, '');
  if (!filtered) return;
  session.ws.send(JSON.stringify({ type: 'input', data: filtered }));
}

/** Send input to a specific session by ID (for approval responses). */
export function sendSSHInputToSession(sessionId: string, data: string): void {
  const session = appState.sessions.get(sessionId);
  if (!session || !isSessionConnected(session) || !session.ws || session.ws.readyState !== WebSocket.OPEN) {
    console.log(`[approval] target session ${sessionId} not connected, falling back to all`);
    sendSSHInputToAll(data);
    return;
  }
  session.ws.send(JSON.stringify({ type: 'input', data }));
}

/** Send input to ALL connected sessions (SSE approval fallback — unknown origin session). */
export function sendSSHInputToAll(data: string): void {
  let sent = 0;
  for (const session of appState.sessions.values()) {
    if (isSessionConnected(session) && session.ws?.readyState === WebSocket.OPEN) {
      session.ws.send(JSON.stringify({ type: 'input', data }));
      sent++;
    }
  }
  console.log(`[approval] sent "${data}" to ${String(sent)} session(s)`);
}

// ── Connection status overlay (#172) ─────────────────────────────────────────

function _showConnectionStatus(message: string, opts?: { error?: boolean; sessionId?: string }): void {
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

  // Capture sessionId for the cancel button closure (#417)
  const sid = opts?.sessionId;

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
  // Pass captured sessionId so disconnect targets the correct session (#417)
  const btn = document.createElement('button');
  btn.className = 'conn-status-cancel';
  btn.textContent = 'Cancel';
  btn.addEventListener('click', () => {
    disconnect(sid);
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
