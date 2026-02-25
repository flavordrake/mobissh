/**
 * modules/terminal.js — Terminal init, resize, keyboard awareness, font & theme
 */

import { THEMES, ANSI, FONT_SIZE } from './constants.js';
import { appState } from './state.js';

// ── CSS layout constants (read from :root once; JS never hardcodes px values) ─

export const ROOT_CSS = (() => {
  const s = getComputedStyle(document.documentElement);
  return {
    tabHeight:      s.getPropertyValue('--tab-height').trim(),
    keybarHeight:   s.getPropertyValue('--keybar-height').trim(),
  };
})();

// ── Terminal ─────────────────────────────────────────────────────────────────

export function initTerminal() {
  const fontSize = parseInt(localStorage.getItem('fontSize')) || 14;
  const savedTheme = localStorage.getItem('termTheme') || 'dark';
  appState.activeThemeName = THEMES[savedTheme] ? savedTheme : 'dark';

  const FONT_FAMILIES = {
    jetbrains: '"JetBrains Mono", monospace',
    firacode:  '"Fira Code", monospace',
    monospace: 'monospace',
  };
  const savedFont = localStorage.getItem('termFont') || 'jetbrains';
  const fontFamily = FONT_FAMILIES[savedFont] || FONT_FAMILIES.jetbrains;

  appState.terminal = new Terminal({
    fontFamily,
    fontSize,
    theme: THEMES[appState.activeThemeName].theme,
    cursorBlink: true,
    scrollback: 5000,
    convertEol: false,
    copyOnSelect: true,
  });

  appState.fitAddon = new FitAddon.FitAddon();
  appState.terminal.loadAddon(appState.fitAddon);
  appState.terminal.open(document.getElementById('terminal'));
  appState.fitAddon.fit();

  // Re-measure character cells after web fonts finish loading (#71)
  document.fonts.ready.then(() => {
    appState.terminal.options.fontFamily = fontFamily;
    appState.fitAddon.fit();
  });

  window.addEventListener('resize', handleResize);

  // Show welcome banner
  appState.terminal.writeln(ANSI.bold(ANSI.green('MobiSSH')));
  appState.terminal.writeln(ANSI.dim('Tap terminal to activate keyboard  •  Use Connect tab to open a session'));
  appState.terminal.writeln('');
}

export function handleResize() {
  if (appState._selectionActive) return; // freeze layout during text selection (#55/#108)
  if (appState.fitAddon) appState.fitAddon.fit();
  if (appState.sshConnected && appState.ws && appState.ws.readyState === WebSocket.OPEN) {
    appState.ws.send(JSON.stringify({
      type: 'resize',
      cols: appState.terminal.cols,
      rows: appState.terminal.rows,
    }));
  }
}

// ── Keyboard visibility awareness ───────────────────────────────────────────

let keyboardVisible = false;

export function getKeyboardVisible() {
  return keyboardVisible;
}

export function initKeyboardAwareness() {
  if (!window.visualViewport) return;

  const app = document.getElementById('app');

  function onViewportChange() {
    const vv = window.visualViewport;
    const h = Math.round(vv.height);

    keyboardVisible = h < window.outerHeight * 0.75;

    app.style.height = `${h}px`;

    if (appState._selectionActive) return;

    if (appState.fitAddon) appState.fitAddon.fit();
    if (appState.terminal) appState.terminal.scrollToBottom();

    if (appState.sshConnected && appState.ws && appState.ws.readyState === WebSocket.OPEN) {
      appState.ws.send(JSON.stringify({ type: 'resize', cols: appState.terminal.cols, rows: appState.terminal.rows }));
    }
  }

  window.visualViewport.addEventListener('resize', onViewportChange);
}

// ── Font size & theme ────────────────────────────────────────────────────────

export function applyFontSize(size) {
  size = Math.max(FONT_SIZE.MIN, Math.min(FONT_SIZE.MAX, size));
  localStorage.setItem('fontSize', size);
  const rangeEl = document.getElementById('fontSize');
  const labelEl = document.getElementById('fontSizeValue');
  const menuLabel = document.getElementById('fontSizeLabel');
  if (rangeEl) rangeEl.value = size;
  if (labelEl) labelEl.textContent = `${size}px`;
  if (menuLabel) menuLabel.textContent = `${size}px`;
  if (appState.terminal) {
    appState.terminal.options.fontSize = size;
    if (appState.fitAddon) appState.fitAddon.fit();
    if (appState.sshConnected && appState.ws && appState.ws.readyState === WebSocket.OPEN) {
      appState.ws.send(JSON.stringify({ type: 'resize', cols: appState.terminal.cols, rows: appState.terminal.rows }));
    }
    if (typeof appState._syncOverlayMetrics === 'function') appState._syncOverlayMetrics();
  }
}

export function applyTheme(name, { persist = false } = {}) {
  const t = THEMES[name];
  if (!t) return;
  appState.activeThemeName = name;
  if (appState.terminal) appState.terminal.options.theme = t.theme;
  if (persist) localStorage.setItem('termTheme', name);
  const menuBtn = document.getElementById('sessionThemeBtn');
  if (menuBtn) menuBtn.textContent = `Theme: ${t.label} ▸`;
  const sel = document.getElementById('termThemeSelect');
  if (sel) sel.value = name;
}
