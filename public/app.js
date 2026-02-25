import { THEMES, ANSI, FONT_SIZE } from './modules/constants.js';
import { appState } from './modules/state.js';
import { initRecording } from './modules/recording.js';
import { initVault } from './modules/vault.js';
import {
  initProfiles, getProfiles, loadProfiles,
  loadProfileIntoForm, deleteProfile,
  loadKeys, importKey, useKey, deleteKey,
} from './modules/profiles.js';
import {
  initSettings, initSettingsPanel, registerServiceWorker,
} from './modules/settings.js';
import { initConnection } from './modules/connection.js';
import { initIME, initIMEInput } from './modules/ime.js';
import {
  initUI, toast, setStatus, focusIME,
  _applyTabBarVisibility, initSessionMenu, initTabBar,
  initConnectForm, initTerminalActions, initKeyBar,
} from './modules/ui.js';

/**
 * MobiSSH PWA — Main application
 *
 * IME Input Strategy:
 *   A visually hidden <textarea id="imeInput"> is kept focused whenever the
 *   terminal is active. Android's IME (Gboard swipe, voice typing, any keyboard)
 *   fires standard DOM 'input' events on any focused editable element — no
 *   Web Speech API needed. We forward every input event to the SSH stream and
 *   immediately clear the textarea value.
 */

// ─── CSS layout constants (read from :root once; JS never hardcodes px values) ─

const ROOT_CSS = (() => {
  const s = getComputedStyle(document.documentElement);
  return {
    tabHeight:      s.getPropertyValue('--tab-height').trim(),
    keybarHeight:   s.getPropertyValue('--keybar-height').trim(),
  };
})();

// ─── Startup ─────────────────────────────────────────────────────────────────

document.addEventListener('DOMContentLoaded', () => {
  try {
    initTerminal();
    initUI({ keyboardVisible: () => keyboardVisible, ROOT_CSS, applyFontSize, applyTheme });
    initIME({ handleResize, applyFontSize });
    initIMEInput();
    initTabBar();
    initConnectForm();
    initTerminalActions();
    initKeyBar();         // #1 auto-hide + #2 IME toggle
    initRecording({ toast });
    initProfiles({ toast });
    initSettings({ toast, applyFontSize, applyTheme });
    initConnection({ toast, setStatus, focusIME, applyTabBarVisibility: _applyTabBarVisibility });
    initSessionMenu();    // #39 handle strip session identity + menu
    initSettingsPanel();
    loadProfiles();
    loadKeys();
    registerServiceWorker();
    initVault(); // async, silently unlocks if browser credential available
    initKeyboardAwareness();

    // Event delegation for profile list — replaces inline onclick blocked by CSP
    const profileList = document.getElementById('profileList');
    profileList.addEventListener('click', (e) => {
      const btn = e.target.closest('[data-action]');
      if (btn) {
        e.stopPropagation();
        const idx = parseInt(btn.dataset.idx);
        if (btn.dataset.action === 'edit') loadProfileIntoForm(idx);
        else if (btn.dataset.action === 'delete') deleteProfile(idx);
        return;
      }
      const item = e.target.closest('.profile-item');
      if (item) loadProfileIntoForm(parseInt(item.dataset.idx));
    });
    profileList.addEventListener('touchstart', (e) => {
      e.target.closest('.profile-item')?.classList.add('tapped');
    }, { passive: true });
    profileList.addEventListener('touchend', (e) => {
      e.target.closest('.profile-item')?.classList.remove('tapped');
    }, { passive: true });

    // Event delegation for key list — replaces inline onclick blocked by CSP
    document.getElementById('keyList').addEventListener('click', async (e) => {
      const btn = e.target.closest('[data-action]');
      if (!btn) return;
      const idx = parseInt(btn.dataset.idx);
      if (btn.dataset.action === 'use') await useKey(idx);
      else if (btn.dataset.action === 'delete') deleteKey(idx);
    });

    // Import key button
    document.getElementById('importKeyBtn').addEventListener('click', async () => {
      const name = document.getElementById('keyName').value.trim();
      const data = document.getElementById('keyData').value.trim();
      if (await importKey(name, data)) {
        document.getElementById('keyName').value = '';
        document.getElementById('keyData').value = '';
      }
    });

    // Cold start UX (#36): if profiles exist, land on Connect so user can tap to connect
    if (getProfiles().length > 0) {
      document.querySelector('[data-panel="connect"]').click();
    }

    // Apply saved font size (applyFontSize syncs all UI)
    applyFontSize(parseInt(localStorage.getItem('fontSize')) || 14);
  } catch (err) {
    console.error('[mobissh] Boot failed:', err);
    // Show the error in the recovery overlay so the user sees what went wrong
    if (typeof window.__appBootError === 'function') window.__appBootError(err);
  }

  // Signal the recovery watchdog that the app booted (even on error — the overlay
  // will show the error instead of the generic "App failed to start" message).
  if (typeof window.__appReady === 'function') window.__appReady();
});

// ─── Terminal ─────────────────────────────────────────────────────────────────

function initTerminal() {
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

function handleResize() {
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

// ─── Keyboard visibility awareness ───────────────────────────────────────────
// The Android soft keyboard shrinks window.visualViewport.height but does NOT
// reliably fire window.resize. We watch visualViewport directly so xterm.js
// always refits and scrolls to keep the cursor above the keyboard.

// Tracks whether the soft keyboard is currently visible (#51).
// Heuristic: if visualViewport.height < 75% of window.outerHeight, keyboard is up.
let keyboardVisible = false;

function initKeyboardAwareness() {
  if (!window.visualViewport) return;

  const app = document.getElementById('app');

  function onViewportChange() {
    const vv = window.visualViewport;
    const h = Math.round(vv.height);

    // Detect keyboard presence: keyboard shrinks the visual viewport below ~75% of screen
    keyboardVisible = h < window.outerHeight * 0.75;

    // Pin #app to the visible viewport height so nothing is clipped behind keyboard
    app.style.height = `${h}px`;

    // Freeze terminal layout while text selection overlay is active (#55/#108).
    // Keyboard dismiss during selection would resize the terminal, invalidating
    // the overlay's synced viewport. Resize happens on exitSelectionMode instead.
    if (appState._selectionActive) return;

    // Refit terminal to the new dimensions
    if (appState.fitAddon) appState.fitAddon.fit();

    // Keep cursor visible — scroll to bottom after keyboard appears
    if (appState.terminal) appState.terminal.scrollToBottom();

    // Tell the server the terminal changed size
    if (appState.sshConnected && appState.ws && appState.ws.readyState === WebSocket.OPEN) {
      appState.ws.send(JSON.stringify({ type: 'resize', cols: appState.terminal.cols, rows: appState.terminal.rows }));
    }
  }

  window.visualViewport.addEventListener('resize', onViewportChange);
}

function applyFontSize(size) {
  size = Math.max(FONT_SIZE.MIN, Math.min(FONT_SIZE.MAX, size));
  localStorage.setItem('fontSize', size);
  // Sync all font-size UI
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
    // Re-sync selection overlay metrics after font change (#55)
    if (typeof appState._syncOverlayMetrics === 'function') appState._syncOverlayMetrics();
  }
}

function applyTheme(name, { persist = false } = {}) {
  const t = THEMES[name];
  if (!t) return;
  appState.activeThemeName = name;
  if (appState.terminal) appState.terminal.options.theme = t.theme;
  if (persist) localStorage.setItem('termTheme', name);
  // Sync session menu label
  const menuBtn = document.getElementById('sessionThemeBtn');
  if (menuBtn) menuBtn.textContent = `Theme: ${t.label} ▸`;
  // Sync settings selector
  const sel = document.getElementById('termThemeSelect');
  if (sel) sel.value = name;
}

// ─── IME input layer — extracted to modules/ime.js ───────────────────────────

// ─── UI chrome — extracted to modules/ui.js ──────────────────────────────────

