/**
 * modules/session.ts — SessionHandle: buffered terminal with debounced resize.
 *
 * Each session owns its Terminal, FitAddon, container, and ResizeObserver.
 * Output is buffered when the session is not foreground and replayed on show().
 * Container resize events are debounced and deduplicated before sending to server.
 */

import type { SSHProfile, ThemeName, SessionLifecycleState, ConnectionCycle } from './types.js';
import { THEMES, RECONNECT } from './constants.js';
import { FONT_FAMILIES } from './terminal.js';

// Filter DA1/DA2/DA3 responses — xterm.js auto-responds to terminal capability
// queries from the remote (CSI c, CSI > c). If not filtered, responses leak
// through to the shell and appear as visible ?1;2c text (#350).
const DA_RESPONSE_RE = /\x1b\[\??[>]?[\d;]*c/g;

/** Max buffered output bytes before oldest chunks are dropped. */
const OUTPUT_BUFFER_MAX_BYTES = 1024 * 1024; // 1 MB

// Detect Claude Code permission prompts in terminal output.
// Strips ANSI escapes before matching so color codes don't break detection.
const ANSI_RE = /\x1b\[[0-9;]*[a-zA-Z]/g;

/** Recent terminal output ring buffer for cross-chunk pattern matching. */
const APPROVAL_BUFFER_MAX = 2048;
const _approvalBuffers = new Map<string, string>();

/**
 * Parse a Claude Code permission prompt from terminal output.
 *
 * Actual format (observed 2026-04-04):
 *   Tool(detail)
 *   Do you want to proceed?
 *   ❯ 2. Yes, allow reading from .claude/ during this session
 *     3. No
 *
 * Also matches: "Allow Tool(detail)?" older format.
 */
export function parseApprovalPrompt(sessionId: string, raw: string): { tool: string; detail: string; description: string; options: { key: string; label: string }[] } | null {
  const prev = _approvalBuffers.get(sessionId) ?? '';
  const combined = (prev + raw).slice(-APPROVAL_BUFFER_MAX);
  _approvalBuffers.set(sessionId, combined);

  const text = combined.replace(ANSI_RE, '');

  // Detect "Do you want to proceed?" — the universal trigger
  if (!text.includes('Do you want to proceed?')) {
    // Also try older "Allow Tool?" format
    if (!text.match(/Allow\s+\w+/)) return null;
  }

  // Extract tool info: "Tool(detail)" or "Tool" line before the prompt
  let tool = '';
  let detail = '';
  const toolMatch = text.match(/(\w+)\(([^)]*)\)/);
  if (toolMatch) {
    tool = toolMatch[1] ?? '';
    detail = toolMatch[2] ?? '';
  }

  // Extract description: the action line before Tool(detail), e.g., "Read file", "Execute command"
  // Look for lines with title-case words that aren't options or box chars
  let description = '';
  const lines = text.split('\n').map(l => l.trim()).filter(l => l.length > 0);
  for (const line of lines) {
    // Skip box-drawing, option lines, empty, "Do you want", "Esc to cancel"
    if (line.match(/^[─═│┌┐└┘├┤┬┴┼╔╗╚╝║]+$/) || line.match(/^\d+\./) || line.match(/^[❯>]/) ||
        line.includes('Do you want') || line.includes('Esc to cancel') || line.includes('proceed')) continue;
    // Skip the Tool(detail) line itself
    if (toolMatch && line.includes(toolMatch[0])) continue;
    // A short descriptive line (2-50 chars, starts with uppercase)
    if (line.length >= 2 && line.length <= 50 && line.match(/^[A-Z]/)) {
      description = line;
      break;
    }
  }

  // Parse numbered options: "N. Label" or "❯ N. Label"
  const options: { key: string; label: string }[] = [];
  const numOptRe = /[❯>]?\s*(\d+)\.\s+(.+?)(?=\s+\d+\.|$)/g;
  let m: RegExpExecArray | null;
  while ((m = numOptRe.exec(text)) !== null) {
    const label = m[2]!.trim().replace(/\s+/g, ' ');
    if (label.length > 0 && label.length < 80) {
      options.push({ key: m[1]!, label });
    }
  }

  // Fallback: yes/no
  if (options.length === 0) {
    options.push({ key: 'y', label: 'Allow' });
    options.push({ key: 'n', label: 'Deny' });
  }

  _approvalBuffers.set(sessionId, '');
  return { tool, detail, description, options };
}

/** Clear approval buffer for a session (e.g., on close). */
export function clearApprovalBuffer(sessionId: string): void {
  _approvalBuffers.delete(sessionId);
}

export class SessionHandle {
  readonly id: string;
  readonly terminal: Terminal;
  readonly fitAddon: FitAddon.FitAddon;
  readonly container: HTMLElement;

  state: SessionLifecycleState;
  profile: SSHProfile | null;
  ws: WebSocket | null;
  activeThemeName: ThemeName;

  private _cycle: ConnectionCycle | null;
  private _reconnectTimer: ReturnType<typeof setTimeout> | null;
  private _reconnectDelay: number;
  private _keepAliveTimer: ReturnType<typeof setInterval> | null;
  private _wsConsecFailures: number;
  private _onDataDisposable: { dispose(): void } | null;
  private _reconnectPromise: Promise<string> | null;

  private _visible: boolean;
  private _outputBuffer: string[];
  private _outputBufferBytes: number;
  private _getExternalWs: (() => WebSocket | null) | null;
  private _resizeObserver: ResizeObserver | null;
  private _resizeTimer: ReturnType<typeof setTimeout> | null;
  private _lastSentCols: number;
  private _lastSentRows: number;

  constructor(id: string, profile: SSHProfile | null) {
    this.id = id;
    this.profile = profile;
    this.state = 'idle';
    this.ws = null;
    this.activeThemeName = profile?.theme ?? 'dark';

    this._cycle = null;
    this._reconnectTimer = null;
    this._reconnectDelay = RECONNECT.INITIAL_DELAY_MS;
    this._keepAliveTimer = null;
    this._wsConsecFailures = 0;
    this._onDataDisposable = null;
    this._reconnectPromise = null;
    this._visible = true;
    this._outputBuffer = [];
    this._outputBufferBytes = 0;
    this._getExternalWs = null;
    this._resizeObserver = null;
    this._resizeTimer = null;
    this._lastSentCols = 0;
    this._lastSentRows = 0;

    const fontSize = parseFloat(localStorage.getItem('fontSize') ?? '14') || 14;
    const savedFont = localStorage.getItem('termFont') ?? 'monospace';
    const fontFamily = FONT_FAMILIES[savedFont] ?? FONT_FAMILIES['monospace']!;

    this.terminal = new Terminal({
      fontFamily,
      fontSize,
      theme: THEMES[this.activeThemeName].theme,
      cursorBlink: true,
      scrollback: 5000,
      convertEol: false,
    });

    this.fitAddon = new FitAddon.FitAddon();
    this.terminal.loadAddon(this.fitAddon);

    if (localStorage.getItem('enableRemoteClipboard') === 'true') {
      this.terminal.loadAddon(new ClipboardAddon.ClipboardAddon());
    }

    this.container = document.createElement('div');
    this.container.dataset['sessionId'] = id;
    this.container.style.width = '100%';
    this.container.style.height = '100%';
    const terminalRoot = document.getElementById('terminal');
    if (terminalRoot) terminalRoot.appendChild(this.container);

    this.terminal.open(this.container);

    // Debounced ResizeObserver — fires when container is resized by UI
    // actions (keybar toggle, tab bar, keyboard). Skips hidden containers.
    if (typeof ResizeObserver !== 'undefined') {
      this._resizeObserver = new ResizeObserver(() => {
        if (!this._visible || this.container.offsetHeight <= 0) return;
        if (this._resizeTimer != null) clearTimeout(this._resizeTimer);
        this._resizeTimer = setTimeout(() => {
          this._resizeTimer = null;
          this.fit();
        }, 100);
      });
      this._resizeObserver.observe(this.container);
    }
  }

  // -- Visibility --

  show(): void {
    this.container.classList.remove('hidden');
    this._visible = true;

    if (this.container.offsetHeight > 0) {
      this.fit();
    }

    if (this._outputBuffer.length > 0) {
      this.terminal.write(this._outputBuffer.join(''));
      this._outputBuffer = [];
      this._outputBufferBytes = 0;
    }
  }

  hide(): void {
    this.container.classList.add('hidden');
    this._visible = false;
  }

  write(data: string): void {
    if (this._visible) {
      this.terminal.write(data);
    } else {
      this._outputBuffer.push(data);
      this._outputBufferBytes += data.length;
      while (this._outputBufferBytes > OUTPUT_BUFFER_MAX_BYTES && this._outputBuffer.length > 1) {
        const dropped = this._outputBuffer.shift()!;
        this._outputBufferBytes -= dropped.length;
      }
    }

    // Detect approval prompts in terminal output
    const prompt = parseApprovalPrompt(this.id, data);
    if (prompt) {
      window.dispatchEvent(new CustomEvent('approval-prompt', {
        detail: { sessionId: this.id, ...prompt },
      }));
    }
  }

  /** Fit terminal to current container size and send resize if dimensions changed. */
  fit(): void {
    if (this.container.offsetHeight <= 0) return;
    this.fitAddon.fit();

    const cols = this.terminal.cols;
    const rows = this.terminal.rows;

    if (cols === this._lastSentCols && rows === this._lastSentRows) return;
    this._lastSentCols = cols;
    this._lastSentRows = rows;

    const ws = this.ws ?? this._getExternalWs?.();
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'resize', cols, rows }));
    }
  }

  setExternalWsLookup(fn: () => WebSocket | null): void {
    this._getExternalWs = fn;
  }

  // -- Connection lifecycle --

  connect(): void {
    this._abortCycle();

    const baseUrl = localStorage.getItem('wsUrl') ?? '';
    const ws = new WebSocket(baseUrl);
    this.ws = ws;
    this._setState('connecting');

    this._cycle = { controller: new AbortController(), disposables: [] };

    if (typeof this.terminal.onData === 'function') {
      const onDataDisp = this.terminal.onData((data: string) => {
        this.sendInput(data);
      });
      this._onDataDisposable = onDataDisp;
      this._cycle.disposables.push(onDataDisp);
    }

    ws.onopen = () => {
      this._wsConsecFailures = 0;
      if (!this.profile) return;

      const authMsg: Record<string, unknown> = {
        type: 'connect',
        host: this.profile.host,
        port: this.profile.port || 22,
        username: this.profile.username,
      };

      if (this.profile.authType === 'key' && this.profile.privateKey) {
        authMsg['privateKey'] = this.profile.privateKey;
        if (this.profile.passphrase) authMsg['passphrase'] = this.profile.passphrase;
      } else {
        authMsg['password'] = this.profile.password ?? '';
      }

      if (this.profile.initialCommand) authMsg['initialCommand'] = this.profile.initialCommand;
      ws.send(JSON.stringify(authMsg));
    };

    ws.onmessage = (event: MessageEvent) => {
      let msg: { type: string; data?: string; message?: string };
      try {
        msg = JSON.parse(event.data as string) as { type: string; data?: string; message?: string };
      } catch {
        return;
      }

      if (msg.type === 'connected') {
        this._setState('connected');
        this._reconnectDelay = RECONNECT.INITIAL_DELAY_MS;
      } else if (msg.type === 'output' && msg.data) {
        this.write(msg.data);
      } else if (msg.type === 'error') {
        if (this.state === 'connecting' || this.state === 'authenticating') {
          this._setState('failed');
        }
      } else if (msg.type === 'disconnected') {
        this._setState('disconnected');
      }
    };

    ws.onclose = () => {
      if (this.state === 'connected') {
        this._setState('disconnected');
      } else if (this.state === 'connecting' || this.state === 'authenticating') {
        this._wsConsecFailures++;
        this._setState('failed');
      }
    };

    ws.onerror = () => {
      // onerror is always followed by onclose
    };
  }

  reconnect(): Promise<string> {
    if (this._reconnectPromise) return this._reconnectPromise;
    if (this.state === 'connected') return Promise.resolve('connected');
    if (!this.profile) return Promise.resolve('no-profile');

    this.connect();

    this._reconnectPromise = new Promise<string>((resolve) => {
      const timer = setTimeout(() => {
        this._reconnectPromise = null;
        resolve('timeout');
      }, 30000);

      const check = setInterval(() => {
        if (this.state === 'connected' || this.state === 'failed' || this.state === 'disconnected' || this.state === 'closed') {
          clearInterval(check);
          clearTimeout(timer);
          this._reconnectPromise = null;
          resolve(this.state);
        }
      }, 50);
    });

    return this._reconnectPromise;
  }

  disconnect(): void {
    this._clearReconnectTimer();
    this._clearKeepAlive();

    if (this.ws) {
      this.ws.onclose = null;
      try {
        this.ws.send(JSON.stringify({ type: 'disconnect' }));
      } catch {
        // may already be closed
      }
      this.ws.close();
      this.ws = null;
    }

    if (this.state !== 'disconnected' && this.state !== 'closed' && this.state !== 'failed') {
      this._setState('disconnected');
    }
  }

  sendInput(data: string): void {
    if (this.state !== 'connected' || !this.ws || this.ws.readyState !== WebSocket.OPEN) {
      return;
    }
    const filtered = data.replace(DA_RESPONSE_RE, '');
    if (!filtered) return;
    this.ws.send(JSON.stringify({ type: 'input', data: filtered }));
  }

  // -- Cleanup --

  close(): void {
    this._abortCycle();

    if (this.ws) {
      this.ws.onclose = null;
      this.ws.close();
      this.ws = null;
    }

    this._clearReconnectTimer();
    this._clearKeepAlive();

    if (this._resizeObserver) {
      this._resizeObserver.disconnect();
      this._resizeObserver = null;
    }
    if (this._resizeTimer != null) {
      clearTimeout(this._resizeTimer);
      this._resizeTimer = null;
    }

    if (this._onDataDisposable) {
      this._onDataDisposable.dispose();
      this._onDataDisposable = null;
    }

    this._outputBuffer = [];
    this._outputBufferBytes = 0;

    this.terminal.dispose();
    this.container.remove();
    this.state = 'closed';
  }

  // -- Internal helpers --

  _setState(target: SessionLifecycleState): void {
    this.state = target;
  }

  private _abortCycle(): void {
    if (this._cycle) {
      this._cycle.controller.abort();
      for (const d of this._cycle.disposables) d.dispose();
      this._cycle = null;
    }
  }

  private _clearReconnectTimer(): void {
    if (this._reconnectTimer != null) {
      clearTimeout(this._reconnectTimer);
      this._reconnectTimer = null;
    }
  }

  private _clearKeepAlive(): void {
    if (this._keepAliveTimer != null) {
      clearInterval(this._keepAliveTimer);
      this._keepAliveTimer = null;
    }
  }
}
