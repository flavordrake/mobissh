/**
 * modules/session.ts — Self-contained SessionHandle class (#374)
 *
 * Buffered terminal — no automatic fit, no ResizeObserver, no timers.
 * Each session owns its Terminal, FitAddon, and container. Output is
 * buffered when the session is not foreground and replayed on show().
 */

import type { SSHProfile, ThemeName, SessionLifecycleState, ConnectionCycle } from './types.js';
import { THEMES, RECONNECT } from './constants.js';

// Filter DA1/DA2/DA3 responses — xterm.js auto-responds to terminal capability
// queries from the remote (CSI c, CSI > c). If not filtered, responses leak
// through to the shell and appear as visible ?1;2c text (#350).
const DA_RESPONSE_RE = /\x1b\[\??[>]?[\d;]*c/g;

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

  /** Whether this session's container is currently visible. */
  private _visible: boolean;
  /** Output buffered while session is not foreground. */
  private _outputBuffer: string[];
  /** Callback to get externally-managed WS (from _openWebSocket in connection.ts). */
  private _getExternalWs: (() => WebSocket | null) | null;
  /** ResizeObserver for container size changes. */
  private _resizeObserver: ResizeObserver | null;
  /** Debounce timer for resize events. */
  private _resizeTimer: ReturnType<typeof setTimeout> | null;
  /** Last sent cols/rows — deduplicate resize messages. */
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
    this._getExternalWs = null;
    this._resizeObserver = null;
    this._resizeTimer = null;
    this._lastSentCols = 0;
    this._lastSentRows = 0;

    // Create terminal
    const fontSize = parseFloat(localStorage.getItem('fontSize') ?? '14') || 14;
    const savedFont = localStorage.getItem('termFont') ?? 'monospace';
    const fontFamilies: Record<string, string> = {
      monospace: 'ui-monospace, Menlo, "Cascadia Code", Consolas, monospace',
      jetbrains: '"JetBrains Mono", monospace',
      firacode: '"Fira Code", monospace',
    };
    const fontFamily = fontFamilies[savedFont] ?? fontFamilies['monospace']!;

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

    // Create per-session container div inside #terminal
    this.container = document.createElement('div');
    this.container.dataset['sessionId'] = id;
    this.container.style.width = '100%';
    this.container.style.height = '100%';
    const terminalRoot = document.getElementById('terminal');
    if (terminalRoot) terminalRoot.appendChild(this.container);

    this.terminal.open(this.container);
    // No fit here — container may not be in a visible panel yet.
    // fit() runs on first show() when the container has real dimensions.

    // ResizeObserver: when the container is resized by UI actions (keybar
    // toggle, tab bar, keyboard), debounce + deduplicate, then fit + send
    // resize to server. Skip if container is hidden (offsetHeight 0).
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

  /** Make this session's container visible. Replays buffered output. */
  show(): void {
    this.container.classList.remove('hidden');
    this._visible = true;

    // Fit to actual container dimensions — only if the container has real
    // layout (parent panel is visible). If the panel isn't active yet,
    // offsetHeight will be 0 and fit() is a no-op.
    if (this.container.offsetHeight > 0) {
      this.fit();
    }

    // Replay buffered output verbatim
    if (this._outputBuffer.length > 0) {
      for (const chunk of this._outputBuffer) {
        this.terminal.write(chunk);
      }
      this._outputBuffer = [];
    }
  }

  /** Hide this session's container. Starts buffering output. */
  hide(): void {
    this.container.classList.add('hidden');
    this._visible = false;
  }

  /**
   * Write output to the terminal. If the session is not foreground,
   * buffer it for replay on show().
   */
  write(data: string): void {
    if (this._visible) {
      this.terminal.write(data);
    } else {
      this._outputBuffer.push(data);
    }
  }

  /** Fit terminal to current container size and send resize if dimensions changed. */
  fit(): void {
    if (this.container.offsetHeight <= 0) return;
    this.fitAddon.fit();

    const cols = this.terminal.cols;
    const rows = this.terminal.rows;

    // Deduplicate — don't send resize if dimensions haven't changed
    if (cols === this._lastSentCols && rows === this._lastSentRows) return;
    this._lastSentCols = cols;
    this._lastSentRows = rows;

    // Send resize via handle's ws or the externally-managed ws
    const ws = this.ws ?? this._getExternalWs?.();
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'resize', cols, rows }));
    }
  }

  // Keep fitIfVisible as an alias for backward compat with wiring code
  fitIfVisible(): void {
    this.fit();
  }

  /** Register a callback to look up the externally-managed WebSocket. */
  setExternalWsLookup(fn: () => WebSocket | null): void {
    this._getExternalWs = fn;
  }

  // -- Connection lifecycle --

  /** Create WebSocket, send auth. Transitions to 'connecting'. */
  connect(): void {
    // Abort previous cycle
    this._abortCycle();

    const baseUrl = localStorage.getItem('wsUrl') ?? '';
    const ws = new WebSocket(baseUrl);
    this.ws = ws;
    this._setState('connecting');

    this._cycle = { controller: new AbortController(), disposables: [] };

    // Wire terminal.onData (may not exist in test mocks)
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
        this.terminal.write(msg.data);
      } else if (msg.type === 'error') {
        // Errors during connection are failures
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

  /** Idempotent reconnect. Returns existing promise if already reconnecting. */
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

      // Poll state changes via a simple check interval
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

  /** Close WebSocket, transition to disconnected. */
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

  /** Send input data through WebSocket. Filters DA responses. */
  sendInput(data: string): void {
    if (this.state !== 'connected' || !this.ws || this.ws.readyState !== WebSocket.OPEN) {
      return;
    }
    const filtered = data.replace(DA_RESPONSE_RE, '');
    if (!filtered) return;
    this.ws.send(JSON.stringify({ type: 'input', data: filtered }));
  }

  // -- Cleanup --

  /** Dispose terminal, abort cycle, remove container from DOM. */
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

    this.terminal.dispose();
    this.container.remove();
    this.state = 'closed';
  }

  // -- Internal helpers --

  /** Exposed for tests: set state directly. */
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
