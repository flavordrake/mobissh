/**
 * modules/terminal.ts — Terminal init, resize, keyboard awareness, font & theme
 */

import type { ThemeName, RootCSS } from './types.js';
import { THEMES, ANSI, FONT_SIZE, escHtml } from './constants.js';
import { appState } from './state.js';

interface NotifEntry {
  time: number;
  message: string;
}

const _notifications: NotifEntry[] = [];

export function getNotifications(): readonly NotifEntry[] {
  return _notifications;
}

export function clearNotifications(): void {
  _notifications.length = 0;
  _updateBellBadge();
  const drawer = document.getElementById('notifDrawer');
  if (drawer) drawer.classList.add('hidden');
}

function _addNotification(message: string): void {
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

// ── CSS layout constants (read from :root once; JS never hardcodes px values) ─

export const ROOT_CSS: RootCSS = (() => {
  const s = getComputedStyle(document.documentElement);
  return {
    tabHeight: s.getPropertyValue('--tab-height').trim(),
    keybarHeight: s.getPropertyValue('--keybar-height').trim(),
  };
})();

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
  if (backgroundOnly && document.visibilityState !== 'hidden') return false;
  const cooldownMs = parseInt(localStorage.getItem('notifCooldown') ?? '15000') || 15000;
  if (Date.now() - _lastNotifTime < cooldownMs) return false;
  return true;
}

function fireNotification(title: string, body: string): void {
  if (!('serviceWorker' in navigator)) return;
  void navigator.serviceWorker.ready.then((reg) => {
    return reg.showNotification(title, { body });
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

  appState.terminal = new Terminal({
    fontFamily,
    fontSize,
    theme: THEMES[appState.activeThemeName].theme,
    cursorBlink: true,
    scrollback: 5000,
    convertEol: false,
  });

  appState.fitAddon = new FitAddon.FitAddon();
  appState.terminal.loadAddon(appState.fitAddon);
  appState.terminal.loadAddon(new ClipboardAddon.ClipboardAddon());
  appState.terminal.open(document.getElementById('terminal')!);
  appState.fitAddon.fit();
  applyTheme(appState.activeThemeName);

  appState.terminal.onBell(() => {
    const buffer = appState.terminal!.buffer.active;
    let body = 'Terminal bell';
    for (let i = buffer.cursorY; i >= 0; i--) {
      const line = buffer.getLine(i)?.translateToString(true).trim();
      if (line) { body = line; break; }
    }
    _addNotification(body);
    if (shouldNotify()) fireNotification('MobiSSH', body);
  });

  appState.terminal.parser.registerOscHandler(9, (data: string) => {
    _addNotification(data);
    if (shouldNotify()) fireNotification('MobiSSH', data);
    return true;
  });

  appState.terminal.parser.registerOscHandler(777, (data: string) => {
    const parts = data.split(';');
    if (parts[0] === 'notify') {
      _addNotification(parts[2] ?? '');
      if (shouldNotify()) fireNotification(parts[1] ?? 'MobiSSH', parts[2] ?? '');
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
    if (!appState.terminal || !fontFamily) return;
    appState.terminal.options.fontFamily = fontFamily;
    appState.fitAddon?.fit();
  });

  window.addEventListener('resize', handleResize);

  // Show welcome banner
  appState.terminal.writeln(ANSI.bold(ANSI.green('MobiSSH')));
  appState.terminal.writeln(ANSI.dim('Tap terminal to activate keyboard  •  Use Connect tab to open a session'));
  appState.terminal.writeln('');
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
  appState.fitAddon?.fit();
  if (appState.sshConnected && appState.ws?.readyState === WebSocket.OPEN) {
    appState.ws.send(JSON.stringify({
      type: 'resize',
      cols: appState.terminal?.cols ?? 80,
      rows: appState.terminal?.rows ?? 24,
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

    appState.fitAddon?.fit();
    appState.terminal?.scrollToBottom();

    if (appState.sshConnected && appState.ws?.readyState === WebSocket.OPEN) {
      appState.ws.send(JSON.stringify({ type: 'resize', cols: appState.terminal?.cols ?? 80, rows: appState.terminal?.rows ?? 24 }));
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
  if (appState.terminal) {
    appState.terminal.options.fontSize = size;
    appState.fitAddon?.fit();
    if (appState.sshConnected && appState.ws?.readyState === WebSocket.OPEN) {
      appState.ws.send(JSON.stringify({ type: 'resize', cols: appState.terminal.cols, rows: appState.terminal.rows }));
    }
  }
}

export function applyTheme(name: string, { persist = false } = {}): void {
  if (!((name as ThemeName) in THEMES)) return;
  const t = THEMES[name as ThemeName];
  appState.activeThemeName = name as ThemeName;
  if (appState.terminal) appState.terminal.options.theme = t.theme;
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
  const menuBtn = document.getElementById('sessionThemeBtn');
  if (menuBtn) menuBtn.textContent = `Theme: ${t.label} ▸`;
  const sel = document.getElementById('termThemeSelect') as HTMLSelectElement | null;
  if (sel) sel.value = name;
}
