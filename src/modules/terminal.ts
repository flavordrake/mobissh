/**
 * modules/terminal.ts — Terminal init, resize, keyboard awareness, font & theme
 */

import type { ThemeName, RootCSS } from './types.js';
import { THEMES, ANSI, FONT_SIZE, escHtml } from './constants.js';
import { appState, currentSession, createSession } from './state.js';

interface NotifEntry {
  time: number;
  message: string;
}

const _notifications: NotifEntry[] = [];
const NOTIF_MAX = 50;
const NOTIF_EXPIRY_MS = 30 * 60 * 1000; // 30 minutes

export function _sanitizeNotifText(raw: string): string {
  let s = raw;
  // Strip ANSI escape sequences: CSI (\x1b[...), OSC (\x1b]...), and other \x1b sequences
  /* eslint-disable no-control-regex */
  s = s.replace(/\x1b\[[0-9;?]*[ -/]*[@-~]/g, '');
  s = s.replace(/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g, '');
  s = s.replace(/\x1b[@-Z\\-_]/g, '');
  // Remove control characters: U+0000-U+001F (except space 0x20), U+007F, U+0080-U+009F
  s = s.replace(/[\x00-\x1f\x7f\x80-\x9f]/g, '');
  /* eslint-enable no-control-regex */
  // Remove Unicode replacement / block characters
  s = s.replace(/[▯\uFFFD]/g, '');
  // Strip leading # from hook-injected messages (e.g., "# Approve: Edit — file.ts")
  s = s.replace(/^#\s*/, '');
  // Collapse whitespace runs to single space and trim
  s = s.replace(/\s+/g, ' ').trim();
  // Truncate to 120 chars with ellipsis
  if (s.length > 120) s = s.slice(0, 117) + '...';
  // Fall back to default if result is empty or too short
  if (s.length < 3) return 'Terminal bell';
  return s;
}

export function getNotifications(): readonly NotifEntry[] {
  const cutoff = Date.now() - NOTIF_EXPIRY_MS;
  let removed = false;
  while (_notifications.length > 0 && _notifications[0]!.time < cutoff) {
    _notifications.shift();
    removed = true;
  }
  if (removed) _updateBellBadge();
  return _notifications;
}

export function clearNotifications(): void {
  _notifications.length = 0;
  _updateBellBadge();
  const drawer = document.getElementById('notifDrawer');
  if (drawer) drawer.classList.add('hidden');
}

export function _addNotification(message: string): void {
  // In-UI bell badge always shows — only Android push is gated by shouldNotify()
  if (message.length < 3) return;
  if (_notifications.length >= NOTIF_MAX) _notifications.shift();
  _notifications.push({ time: Date.now(), message });
  _updateBellBadge();
}

function _updateBellBadge(): void {
  const btn = document.getElementById('bellIndicatorBtn');
  const badge = btn?.querySelector('.bell-badge');
  if (!btn || !badge) return;
  const count = _notifications.length;
  btn.classList.toggle('hidden', count === 0);
  badge.classList.toggle('hidden', count === 0);
  badge.textContent = String(count);
}

// ── CSS layout constants (read from :root on first access; JS never hardcodes px values) ─

let _rootCSS: RootCSS | null = null;
export function getRootCSS(): RootCSS {
  if (!_rootCSS) {
    const s = getComputedStyle(document.documentElement);
    _rootCSS = {
      tabHeight: s.getPropertyValue('--tab-height').trim(),
      keybarHeight: s.getPropertyValue('--keybar-height').trim(),
    };
  }
  return _rootCSS;
}

// ── Terminal ─────────────────────────────────────────────────────────────────

const FONT_FAMILIES: Record<string, string> = {
  monospace: 'ui-monospace, Menlo, "Cascadia Code", Consolas, monospace',
  jetbrains: '"JetBrains Mono", monospace',
  firacode: '"Fira Code", monospace',
};

let _lastNotifTime = 0;

function shouldNotify(): boolean {
  if (localStorage.getItem('termNotifications') !== 'true') return false;
  if (Notification.permission !== 'granted') return false;
  const backgroundOnly = localStorage.getItem('notifBackgroundOnly') !== 'false';
  // Only suppress if BOTH signals confirm user is actively looking at the app.
  // Android PWA: hasFocus() can be true when backgrounded, visibilityState can
  // stay 'visible' during app switching. Either alone is unreliable.
  if (backgroundOnly && document.hasFocus() && document.visibilityState === 'visible') return false;
  const cooldownMs = parseInt(localStorage.getItem('notifCooldown') ?? '15000') || 15000;
  if (Date.now() - _lastNotifTime < cooldownMs) return false;
  return true;
}

export function fireNotification(title: string, body: string): void {
  if (!('serviceWorker' in navigator)) return;
  void navigator.serviceWorker.ready.then((reg) => {
    return reg.showNotification(title, { body, tag: 'mobissh-agent' });
  }).then(() => {
    _lastNotifTime = Date.now();
  }).catch(() => { /* permission may have been revoked */ });
}

export function initTerminal(): void {
  const fontSize = parseFloat(localStorage.getItem('fontSize') ?? '14') || 14;
  const savedTheme = localStorage.getItem('termTheme') ?? 'dark';
  appState.activeThemeName = ((savedTheme as ThemeName) in THEMES ? savedTheme : 'dark') as ThemeName;

  const savedFont = localStorage.getItem('termFont') ?? 'monospace';
  const fontFamily = FONT_FAMILIES[savedFont] ?? FONT_FAMILIES.monospace;

  // Create a lobby session for the welcome terminal
  const lobby = createSession('lobby');
  appState.activeSessionId = 'lobby';

  const terminal = new Terminal({
    fontFamily,
    fontSize,
    theme: THEMES[appState.activeThemeName].theme,
    cursorBlink: true,
    scrollback: 5000,
    convertEol: false,
  });

  const fitAddon = new FitAddon.FitAddon();
  terminal.loadAddon(fitAddon);
  if (localStorage.getItem('enableRemoteClipboard') === 'true') {
    terminal.loadAddon(new ClipboardAddon.ClipboardAddon());
  }
  // Lobby terminal gets a container div like session terminals (#261)
  // so switchSession() can hide it when a real session connects.
  const lobbyContainer = document.createElement('div');
  lobbyContainer.dataset['sessionId'] = 'lobby';
  lobbyContainer.style.width = '100%';
  lobbyContainer.style.height = '100%';
  document.getElementById('terminal')!.appendChild(lobbyContainer);
  terminal.open(lobbyContainer);
  fitAddon.fit();

  lobby.terminal = terminal;
  lobby.fitAddon = fitAddon;

  applyTheme(appState.activeThemeName);

  terminal.onBell(() => {
    const buffer = terminal.buffer.active;
    let body = 'Terminal bell';
    for (let i = buffer.cursorY; i >= 0; i--) {
      const line = buffer.getLine(i)?.translateToString(true).trim();
      if (line) { body = _sanitizeNotifText(line); break; }
    }
    _addNotification(body);
    if (shouldNotify()) fireNotification('MobiSSH', body);
  });

  terminal.parser.registerOscHandler(9, (data: string) => {
    const body = _sanitizeNotifText(data);
    _addNotification(body);
    if (shouldNotify()) fireNotification('MobiSSH', body);
    return true;
  });

  terminal.parser.registerOscHandler(777, (data: string) => {
    const parts = data.split(';');
    if (parts[0] === 'notify') {
      const body = _sanitizeNotifText(parts[2] ?? '');
      _addNotification(body);
      if (shouldNotify()) fireNotification(parts[1] ?? 'MobiSSH', body);
    }
    return true;
  });

  // Notification drawer toggle (#34)
  const bellBtn = document.getElementById('bellIndicatorBtn');
  if (bellBtn) {
    bellBtn.addEventListener('click', () => {
      _toggleNotifDrawer();
    });
  }

  const clearAllBtn = document.getElementById('notifClearAllBtn');
  if (clearAllBtn) {
    clearAllBtn.addEventListener('click', () => {
      clearNotifications();
      _toggleNotifDrawer(false);
    });
  }

  // Re-measure character cells after web fonts finish loading (#71)
  void document.fonts.ready.then(() => {
    const t = currentSession()?.terminal;
    if (!t || !fontFamily) return;
    t.options.fontFamily = fontFamily;
    currentSession()?.fitAddon?.fit();
  });

  window.addEventListener('resize', handleResize);

  // Show welcome banner
  terminal.writeln(ANSI.bold(ANSI.green('MobiSSH')));
  terminal.writeln(ANSI.dim('Tap terminal to activate keyboard  •  Use Connect tab to open a session'));
  terminal.writeln('');
}

/**
 * Create a Terminal + FitAddon for a specific session, in its own DOM container
 * inside #terminal with data-session-id. Returns { terminal, fitAddon } for the
 * caller to store in SessionState. (#261 — Part A of multi-terminal infrastructure)
 */
export function createSessionTerminal(sessionId: string): { terminal: Terminal; fitAddon: FitAddon.FitAddon } {
  const fontSize = parseFloat(localStorage.getItem('fontSize') ?? '14') || 14;
  const savedFont = localStorage.getItem('termFont') ?? 'monospace';
  const fontFamily = FONT_FAMILIES[savedFont] ?? FONT_FAMILIES.monospace;

  const terminal = new Terminal({
    fontFamily,
    fontSize,
    theme: THEMES[appState.activeThemeName].theme,
    cursorBlink: true,
    scrollback: 5000,
    convertEol: false,
  });

  const fitAddon = new FitAddon.FitAddon();
  terminal.loadAddon(fitAddon);
  if (localStorage.getItem('enableRemoteClipboard') === 'true') {
    terminal.loadAddon(new ClipboardAddon.ClipboardAddon());
  }

  // Create a per-session container div inside #terminal
  const container = document.createElement('div');
  container.dataset['sessionId'] = sessionId;
  container.style.width = '100%';
  container.style.height = '100%';
  document.getElementById('terminal')!.appendChild(container);

  terminal.open(container);
  fitAddon.fit();

  // Wire bell handler
  terminal.onBell(() => {
    const buffer = terminal.buffer.active;
    let body = 'Terminal bell';
    for (let i = buffer.cursorY; i >= 0; i--) {
      const line = buffer.getLine(i)?.translateToString(true).trim();
      if (line) { body = _sanitizeNotifText(line); break; }
    }
    _addNotification(body);
    if (shouldNotify()) fireNotification('MobiSSH', body);
  });

  // Wire OSC handlers
  terminal.parser.registerOscHandler(9, (data: string) => {
    const body = _sanitizeNotifText(data);
    _addNotification(body);
    if (shouldNotify()) fireNotification('MobiSSH', body);
    return true;
  });

  terminal.parser.registerOscHandler(777, (data: string) => {
    const parts = data.split(';');
    if (parts[0] === 'notify') {
      const body = _sanitizeNotifText(parts[2] ?? '');
      _addNotification(body);
      if (shouldNotify()) fireNotification(parts[1] ?? 'MobiSSH', body);
    }
    return true;
  });

  return { terminal, fitAddon };
}

function _toggleNotifDrawer(show?: boolean): void {
  const drawer = document.getElementById('notifDrawer');
  if (!drawer) return;
  const isHidden = drawer.classList.contains('hidden');
  const shouldShow = show ?? isHidden;
  drawer.classList.toggle('hidden', !shouldShow);
  if (shouldShow) _renderNotifDrawer();
}

function _renderNotifDrawer(): void {
  const list = document.getElementById('notifDrawerList');
  if (!list) return;
  list.innerHTML = '';
  const entries = getNotifications();
  if (entries.length === 0) {
    const empty = document.createElement('div');
    empty.className = 'notif-drawer-empty';
    empty.textContent = 'No notifications';
    list.appendChild(empty);
    return;
  }
  for (let i = entries.length - 1; i >= 0; i--) {
    const entry = entries[i]!;
    const div = document.createElement('div');
    div.className = 'notif-entry';
    const timeStr = new Date(entry.time).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
    div.innerHTML = `<div class="notif-entry-body"><div class="notif-entry-time">${timeStr}</div>${escHtml(entry.message)}</div>`;
    const dismissBtn = document.createElement('button');
    dismissBtn.className = 'notif-dismiss-btn';
    dismissBtn.textContent = '\u00d7';
    dismissBtn.title = 'Dismiss';
    const idx = i;
    dismissBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      _notifications.splice(idx, 1);
      _updateBellBadge();
      _renderNotifDrawer();
    });
    div.appendChild(dismissBtn);
    list.appendChild(div);
  }
}

export function handleResize(): void {
  const session = currentSession();
  session?.fitAddon?.fit();
  if (session?.sshConnected && session.ws?.readyState === WebSocket.OPEN) {
    session.ws.send(JSON.stringify({
      type: 'resize',
      cols: session.terminal?.cols ?? 80,
      rows: session.terminal?.rows ?? 24,
    }));
  }
}

// ── Keyboard visibility awareness ───────────────────────────────────────────

let keyboardVisible = false;

export function getKeyboardVisible(): boolean {
  return keyboardVisible;
}

export function initKeyboardAwareness(): void {
  if (!window.visualViewport) return;

  const app = document.getElementById('app');
  if (!app) return;

  function onViewportChange(): void {
    const vv = window.visualViewport;
    if (!vv) return;

    // Ignore pinch-zoom — only respond to keyboard-driven viewport changes.
    // When scale ≠ 1 the user is zoomed; layout must stay fixed so the key bar
    // does not reflow on top of the terminal (#139).
    // (user-scalable=no is ignored by iOS 10+ / modern Android for a11y, so
    // pinch-zoom still fires visualViewport resize events even though we ask for
    // it not to.)
    if (Math.abs(vv.scale - 1) > 0.01) return;

    const h = Math.round(vv.height);

    keyboardVisible = h < window.outerHeight * 0.75;

    if (vv.scale === 1) {
      app!.style.height = `${String(h)}px`;
      document.documentElement.style.setProperty('--viewport-height', `${String(h)}px`);
    }

    const session = currentSession();
    session?.fitAddon?.fit();
    session?.terminal?.scrollToBottom();

    if (session?.sshConnected && session.ws?.readyState === WebSocket.OPEN) {
      session.ws.send(JSON.stringify({ type: 'resize', cols: session.terminal?.cols ?? 80, rows: session.terminal?.rows ?? 24 }));
    }
  }

  window.visualViewport.addEventListener('resize', onViewportChange);
}

// ── Font size & theme ────────────────────────────────────────────────────────

export function applyFontSize(size: number): void {
  size = Math.max(FONT_SIZE.MIN, Math.min(FONT_SIZE.MAX, size));
  localStorage.setItem('fontSize', String(size));
  const rangeEl = document.getElementById('fontSize') as HTMLInputElement | null;
  const labelEl = document.getElementById('fontSizeValue');
  const menuLabel = document.getElementById('fontSizeLabel');
  if (rangeEl) rangeEl.value = String(size);
  const sizeStr = Number.isInteger(size) ? String(size) : size.toFixed(1);
  if (labelEl) labelEl.textContent = `${sizeStr}px`;
  if (menuLabel) menuLabel.textContent = `${sizeStr}px`;
  const session = currentSession();
  if (session?.terminal) {
    session.terminal.options.fontSize = size;
    session.fitAddon?.fit();
    if (session.sshConnected && session.ws?.readyState === WebSocket.OPEN) {
      session.ws.send(JSON.stringify({ type: 'resize', cols: session.terminal.cols, rows: session.terminal.rows }));
    }
  }
}

export function applyTheme(name: string, { persist = false } = {}): void {
  if (!((name as ThemeName) in THEMES)) return;
  const t = THEMES[name as ThemeName];
  appState.activeThemeName = name as ThemeName;
  const term = currentSession()?.terminal;
  if (term) term.options.theme = t.theme;
  if (persist) localStorage.setItem('termTheme', name);
  const { style } = document.documentElement;
  style.setProperty('--terminal-bg', t.theme.background);
  style.setProperty('--bg-deep', t.app.bgDeep);
  style.setProperty('--bg-panel', t.app.bgPanel);
  style.setProperty('--bg-card', t.app.bgCard);
  style.setProperty('--bg-input', t.app.bgInput);
  style.setProperty('--text', t.app.text);
  style.setProperty('--text-dim', t.app.textDim);
  style.setProperty('--border', t.app.border);
  style.setProperty('--accent', t.app.accent);
  style.setProperty('--accent-dim', t.app.accentDim);
  const termContainer = document.getElementById('terminal');
  if (termContainer) termContainer.dataset['theme'] = name;
  const menuBtn = document.getElementById('sessionThemeBtn');
  if (menuBtn) menuBtn.textContent = `Theme: ${t.label} ▸`;
  const sel = document.getElementById('termThemeSelect') as HTMLSelectElement | null;
  if (sel) sel.value = name;
}
