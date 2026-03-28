/**
 * modules/session.ts — Self-contained SessionHandle class (#374)
 *
 * Single fit path, self-contained terminal lifecycle. Each SessionHandle owns
 * its Terminal, FitAddon, container div, and ResizeObserver. The class is NOT
 * wired into the app yet — follow-up PRs will migrate existing code.
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
  private _resizeObserver: ResizeObserver | null;
  private _onDataDisposable: { dispose(): void } | null;
  private _reconnectPromise: Promise<string> | null;

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
    this._resizeObserver = null;
    this._onDataDisposable = null;
    this._reconnectPromise = null;

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

    // Set up ResizeObserver — calls fitIfVisible on size changes
    if (typeof ResizeObserver !== 'undefined') {
      this._resizeObserver = new ResizeObserver(() => {
        this.fitIfVisible();
      });
      this._resizeObserver.observe(this.container);
    }
  }

  // -- Terminal lifecycle: ONE fit path --

  /** Remove 'hidden' class; ResizeObserver fires -> fitIfVisible runs. */
  show(): void {
    this.container.classList.remove('hidden');
  }

  /** Add 'hidden' class; container goes to zero height -> fitIfVisible no-ops. */
  hide(): void {
    this.container.classList.add('hidden');
  }

  /** ONLY method that calls fitAddon.fit(). Guards on container.offsetHeight > 0. */
  fitIfVisible(): void {
    if (this.container.offsetHeight <= 0) return;
    this.fitAddon.fit();
    this.terminal.refresh(0, this.terminal.rows - 1);

    // Send resize to server if WS is open
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify({
        type: 'resize',
        cols: this.terminal.cols,
        rows: this.terminal.rows,
      }));
    }
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
