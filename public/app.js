import {
  THEMES, ANSI, KEY_MAP, FONT_SIZE, SELECTION_OVERLAY,
} from './modules/constants.js';
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
  clearCacheAndReload,
} from './modules/settings.js';
import { initConnection, sendSSHInput } from './modules/connection.js';
import {
  initUI, toast, setStatus, focusIME, setCtrlActive,
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

// ─── IME Input Layer ──────────────────────────────────────────────────────────

function initIMEInput() {
  const ime = document.getElementById('imeInput');

  // ── IME composition preview helper (#44) ──────────────────────────────
  // Shows a strip above the handle bar with the word currently being composed.
  // Called with text while composing; called with null/'' to hide.
  function _imePreviewShow(text) {
    const el = document.getElementById('imePreview');
    if (!el) return;
    if (text) {
      el.textContent = text;
      el.classList.remove('hidden');
    } else {
      el.classList.add('hidden');
    }
  }

  // ── input event ─────────────────────────────────────────────────────────
  // Fires for: swipe-typed words, voice-dictated text, regular key presses.
  // For swipe and voice the full word (or sentence) arrives as ime.value.
  // NOTE: direct mode keeps this path too — on Android soft keyboards,
  // keydown always fires e.key='Unidentified', so input is the only reliable
  // path for printable chars. e.preventDefault() in the keydown direct-mode
  // branch already suppresses duplicates from Bluetooth keyboards.
  ime.addEventListener('input', (_e) => {
    if (appState.isComposing) {
      // Update preview with current composition text while the user is typing
      _imePreviewShow(ime.value || null);
      return;
    }
    const text = ime.value;
    ime.value = '';
    if (!text) return;
    // GBoard sends '\n' for Enter via input events — remap to '\r' for SSH
    if (text === '\n') { sendSSHInput('\r'); return; }
    if (appState.ctrlActive) {
      const code = text[0].toLowerCase().charCodeAt(0) - 96;
      sendSSHInput(code >= 1 && code <= 26 ? String.fromCharCode(code) : text);
      setCtrlActive(false);
    } else {
      sendSSHInput(text);
    }
  });

  // ── IME composition (multi-step input methods, e.g. CJK, Gboard swipe) ─
  ime.addEventListener('compositionstart', () => {
    appState.isComposing = true;
    // Preview strip appears on first compositionupdate or input event
  });

  // compositionupdate: fires repeatedly as Gboard refines the word candidate.
  // Update preview text as the user's finger moves across the swipe keyboard.
  ime.addEventListener('compositionupdate', (e) => {
    if (e.data) _imePreviewShow(e.data);
  });

  // On Android, GBoard wraps EVERY soft-keyboard tap in a composition cycle.
  // This means ctrlActive combos (e.g. Ctrl+b for tmux) must be handled here.
  // GBoard also sends '\n' for Enter via compositionend — remap to '\r'.
  ime.addEventListener('compositionend', (e) => {
    appState.isComposing = false;
    _imePreviewShow(null); // hide preview on commit
    // Prefer ime.value (full accumulated phrase) over e.data, which on Android
    // voice dictation is often "" or only the last recognised word.
    const text = ime.value || e.data;
    ime.value = '';
    if (!text) return;
    if (text === '\n') { sendSSHInput('\r'); return; }
    if (appState.ctrlActive) {
      const code = text[0].toLowerCase().charCodeAt(0) - 96;
      sendSSHInput(code >= 1 && code <= 26 ? String.fromCharCode(code) : text);
      setCtrlActive(false);
    } else {
      sendSSHInput(text);
    }
  });

  // compositioncancel fires when the IME aborts the composition without
  // committing (focus loss, external textarea.value write during composition,
  // voice recognition interrupted by terminal output, etc.).
  // Without this handler isComposing stays true permanently and every
  // subsequent input event is silently discarded as "preview only".
  ime.addEventListener('compositioncancel', () => {
    appState.isComposing = false;
    _imePreviewShow(null);
    ime.value = '';
  });

  // ── keydown: special keys not captured by 'input' ─────────────────────
  // In IME mode: handles Ctrl combos and special keys; printable chars come via 'input'.
  // In direct mode: also forwards every printable character immediately, bypassing
  //   IME processing — lower latency, no autocorrect, best with a BT keyboard.
  ime.addEventListener('keydown', (e) => {
    // Ctrl+<letter> combos → control characters (both modes)
    if (e.ctrlKey && !e.altKey && e.key.length === 1) {
      const code = e.key.toLowerCase().charCodeAt(0) - 96;
      if (code >= 1 && code <= 26) {
        sendSSHInput(String.fromCharCode(code));
        e.preventDefault();
        return;
      }
    }

    // Mapped special keys (both modes)
    if (KEY_MAP[e.key]) {
      sendSSHInput(KEY_MAP[e.key]);
      e.preventDefault();
      return;
    }

    // Direct mode only: forward printable characters char-by-char, skip IME
    if (!appState.imeMode && e.key.length === 1 && !e.ctrlKey && !e.altKey && !e.metaKey) {
      if (appState.ctrlActive) {
        const code = e.key.toLowerCase().charCodeAt(0) - 96;
        sendSSHInput(code >= 1 && code <= 26 ? String.fromCharCode(code) : e.key);
        setCtrlActive(false);
      } else {
        sendSSHInput(e.key);
      }
      e.preventDefault();
      ime.value = '';
    }
  });

  // termEl used by selection overlay, gesture handlers, and pinch-to-zoom below
  const termEl = document.getElementById('terminal');

  // ── Selection overlay for mobile copy (#55) ──────────────────────────
  // Mirrors visible terminal text as real DOM nodes so the OS can offer native
  // long-press → select → copy. Normally pointer-events:none; activated on
  // long-press (500ms hold).

  const selOverlay = document.getElementById('selectionOverlay');
  const selBar = document.getElementById('selectionBar');
  let _overlayCellH = 0; // cached cell height from last metric sync

  // URL regex — matches http/https URLs, strips common trailing punctuation
  const URL_RE = /https?:\/\/[^\s<>"')\]]+/g;
  function _stripTrailingPunct(url) {
    return url.replace(/[.,;:!?)]+$/, '');
  }

  // Compute and apply font metrics so overlay lines align with canvas cells
  appState._syncOverlayMetrics = function _syncOverlayMetricsFn() {
    if (!appState.terminal || !selOverlay) return;
    const screen = document.querySelector('.xterm-screen');
    if (!screen) return;
    const cellH = screen.offsetHeight / appState.terminal.rows;
    const cellW = screen.offsetWidth / appState.terminal.cols;
    _overlayCellH = cellH;
    selOverlay.style.fontFamily = appState.terminal.options.fontFamily;
    selOverlay.style.fontSize = appState.terminal.options.fontSize + 'px';
    selOverlay.style.lineHeight = cellH + 'px';
    // Padding to match xterm-screen position inside #terminal
    const screenRect = screen.getBoundingClientRect();
    const termRect = termEl.getBoundingClientRect();
    selOverlay.style.top = (screenRect.top - termRect.top) + 'px';
    selOverlay.style.left = (screenRect.left - termRect.left) + 'px';
    selOverlay.style.width = screenRect.width + 'px';
    selOverlay.style.height = screenRect.height + 'px';
    // Letter-spacing to match monospace cell width
    const testSpan = document.createElement('span');
    testSpan.style.font = appState.terminal.options.fontSize + 'px ' + appState.terminal.options.fontFamily;
    testSpan.style.visibility = 'hidden';
    testSpan.style.position = 'absolute';
    testSpan.textContent = 'M';
    document.body.appendChild(testSpan);
    const charW = testSpan.getBoundingClientRect().width;
    document.body.removeChild(testSpan);
    const spacing = cellW - charW;
    selOverlay.style.letterSpacing = spacing + 'px';
  };

  // Populate overlay with current viewport text + URL detection
  function syncSelectionOverlay() {
    if (!appState.terminal || !selOverlay) return;
    appState._syncOverlayMetrics();
    const buf = appState.terminal.buffer.active;
    const startLine = buf.viewportY;
    const frag = document.createDocumentFragment();
    for (let i = 0; i < appState.terminal.rows; i++) {
      const line = buf.getLine(startLine + i);
      const text = line ? line.translateToString(true) : '';
      const div = document.createElement('div');
      div.className = 'sel-line';
      if (_overlayCellH) div.style.height = _overlayCellH + 'px';
      // Detect and wrap URLs
      let lastIdx = 0;
      let match;
      URL_RE.lastIndex = 0;
      let hasUrl = false;
      while ((match = URL_RE.exec(text)) !== null) {
        hasUrl = true;
        const url = _stripTrailingPunct(match[0]);
        if (match.index > lastIdx) {
          div.appendChild(document.createTextNode(text.slice(lastIdx, match.index)));
        }
        const span = document.createElement('span');
        span.className = 'sel-url';
        span.dataset.url = url;
        span.textContent = url;
        div.appendChild(span);
        lastIdx = match.index + match[0].length;
      }
      if (lastIdx < text.length || !hasUrl) {
        div.appendChild(document.createTextNode(text.slice(lastIdx)));
      }
      frag.appendChild(div);
    }
    selOverlay.innerHTML = '';
    selOverlay.appendChild(frag);
  }

  function _selectAllOverlay() {
    if (!selOverlay.firstChild) return;
    const range = document.createRange();
    range.selectNodeContents(selOverlay);
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
  }

  function enterSelectionMode(x, y) {
    if (appState._selectionActive) return;
    appState._selectionActive = true;
    syncSelectionOverlay();
    selOverlay.classList.add('active');

    // Try to select the word at the touch point first
    let selected = false;
    if (document.caretRangeFromPoint) {
      const range = document.caretRangeFromPoint(x, y);
      if (range && range.startContainer.nodeType === Node.TEXT_NODE) {
        _expandToWord(range);
        const wordText = range.toString().trim();
        if (wordText.length > 0) {
          const sel = window.getSelection();
          sel.removeAllRanges();
          sel.addRange(range);
          selected = true;
        }
      }
    }
    // Fallback: select all visible text if word selection failed
    if (!selected) _selectAllOverlay();

    selBar.classList.remove('hidden');
    _updateSelBar();
  }

  function exitSelectionMode() {
    appState._selectionActive = false;
    selOverlay.classList.remove('active');
    selOverlay.innerHTML = ''; // clear stale content (URL underlines etc.)
    selBar.classList.add('hidden');
    window.getSelection().removeAllRanges();
    // Re-focus IME synchronously so the user gesture context is preserved —
    // Android won't open the keyboard from a setTimeout-delayed focus() (#108).
    focusIME();
    // Catch up on viewport changes suppressed during selection (keyboard
    // dismiss may have changed the visual viewport). Delay lets the keyboard
    // animation settle before we refit.
    setTimeout(handleResize, 200);
  }

  // Expand a caret range to the surrounding word boundary
  function _expandToWord(range) {
    const node = range.startContainer;
    const text = node.textContent;
    let start = range.startOffset;
    let end = start;
    // Word chars: anything except whitespace
    while (start > 0 && !/\s/.test(text[start - 1])) start--;
    while (end < text.length && !/\s/.test(text[end])) end++;
    range.setStart(node, start);
    range.setEnd(node, end);
  }

  // Check if the current selection contains a URL and update copy bar
  function _updateSelBar() {
    const sel = window.getSelection();
    const text = sel.toString();
    const openBtn = document.getElementById('selOpenBtn');
    // Check if selection is inside or overlaps a .sel-url span
    let url = null;
    if (sel.anchorNode) {
      const urlEl = sel.anchorNode.parentElement && sel.anchorNode.parentElement.closest('.sel-url');
      if (urlEl) url = urlEl.dataset.url;
    }
    if (!url) {
      // Fallback: check if selected text itself looks like a URL
      const m = text.match(/https?:\/\/[^\s]+/);
      if (m) url = _stripTrailingPunct(m[0]);
    }
    if (url) {
      openBtn.classList.remove('hidden');
      openBtn.dataset.url = url;
    } else {
      openBtn.classList.add('hidden');
    }
  }

  // Copy bar button handlers
  document.getElementById('selAllBtn').addEventListener('click', (e) => {
    e.stopPropagation();
    _selectAllOverlay();
    _updateSelBar();
  });

  document.getElementById('selCopyBtn').addEventListener('click', (e) => {
    e.stopPropagation();
    const text = window.getSelection().toString();
    if (text) {
      navigator.clipboard.writeText(text).then(() => toast('Copied')).catch(() => toast('Copy failed'));
    }
    exitSelectionMode();
  });

  document.getElementById('selOpenBtn').addEventListener('click', (e) => {
    e.stopPropagation();
    const url = e.currentTarget.dataset.url;
    if (url) window.open(url, '_blank', 'noopener');
    exitSelectionMode();
  });

  document.getElementById('selDoneBtn').addEventListener('click', (e) => {
    e.stopPropagation();
    exitSelectionMode();
  });

  // Listen for selection changes to update the copy bar state
  document.addEventListener('selectionchange', () => {
    if (!appState._selectionActive) return;
    _updateSelBar();
    // Auto-dismiss if selection is cleared
    const sel = window.getSelection();
    if (!sel.toString()) {
      // Small delay — selection can briefly be empty during handle drag
      setTimeout(() => {
        if (appState._selectionActive && !window.getSelection().toString()) {
          exitSelectionMode();
        }
      }, 300);
    }
  });

  // URL tap handler — when in selection mode, tapping a URL auto-selects it
  selOverlay.addEventListener('click', (e) => {
    if (!appState._selectionActive) return;
    const urlEl = e.target.closest('.sel-url');
    if (urlEl) {
      const range = document.createRange();
      range.selectNodeContents(urlEl);
      const sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(range);
      _updateSelBar();
      e.preventDefault();
    }
  });

  // Suppress browser's "Paste" context menu on terminal long-press (#55)
  if (SELECTION_OVERLAY) {
    termEl.addEventListener('contextmenu', (e) => e.preventDefault());
  }

  // Long-press detection — 500ms hold without movement activates selection mode
  let _longPressTimer = null;
  let _longPressX = 0;
  let _longPressY = 0;
  const LONG_PRESS_MS = 500;
  const LONG_PRESS_MOVE_THRESHOLD = 8; // px

  function _startLongPress(x, y) {
    _longPressX = x;
    _longPressY = y;
    _cancelLongPress();
    _longPressTimer = setTimeout(() => {
      _longPressTimer = null;
      enterSelectionMode(x, y);
    }, LONG_PRESS_MS);
  }

  function _cancelLongPress() {
    if (_longPressTimer) {
      clearTimeout(_longPressTimer);
      _longPressTimer = null;
    }
  }


  // ── Tap + swipe gestures on terminal (#32/#37/#16) ────────────────────
  // SWIPE_GESTURES: JS touch→scroll handler.  touch-action:none on #terminal
  // (#37) blocks native pan; this handler provides vertical scroll (both tmux
  // mouse-mode SGR sequences and xterm.js local scrollback) and horizontal
  // swipe for tmux window switching (#16).  Set false only to test native
  // xterm.js scrollbar / long-press copy without our gesture layer.
  const SWIPE_GESTURES = true;

  termEl.addEventListener('click', focusIME);

  let _touchStartY = null, _touchStartX = null;
  let _lastTouchY  = null, _lastTouchX  = null;
  let _isTouchScroll = false;
  let _scrolledLines = 0; // lines already scrolled in this gesture (absolute from start)
  let _pendingLines = 0;  // delta queued for next rAF flush
  let _pendingSGR = null; // { btn, col, row, count } queued for next rAF flush
  let _scrollRafId = null;

  // Flush once per animation frame — prevents flooding xterm.js / the SSH pipe.
  function _flushScroll() {
    _scrollRafId = null;
    if (_pendingLines !== 0 && appState.terminal) {
      appState.terminal.scrollLines(_pendingLines);
      _pendingLines = 0;
    }
    if (_pendingSGR && _pendingSGR.count > 0) {
      const { btn, col, row, count } = _pendingSGR;
      for (let i = 0; i < count; i++) sendSSHInput(`\x1b[<${btn};${col};${row}M`);
      _pendingSGR = null;
    }
  }

  function _scheduleScrollFlush() {
    if (!_scrollRafId) _scrollRafId = requestAnimationFrame(_flushScroll);
  }

  if (SWIPE_GESTURES) {
  // capture:true — fires before xterm.js bubble-phase listeners on canvas/viewport,
  // so stopPropagation() inside xterm.js doesn't swallow our gesture tracking.
  termEl.addEventListener('touchstart', (e) => {
    _touchStartY = _lastTouchY = e.touches[0].clientY;
    _touchStartX = _lastTouchX = e.touches[0].clientX;
    _isTouchScroll = false;
    _scrolledLines = 0;
    _pendingLines = 0;
    _pendingSGR = null;
    if (_scrollRafId) { cancelAnimationFrame(_scrollRafId); _scrollRafId = null; }
    // Start long-press detection (#55) — single finger only
    if (SELECTION_OVERLAY && e.touches.length === 1 && !appState._selectionActive) {
      _startLongPress(e.touches[0].clientX, e.touches[0].clientY);
    }
  }, { passive: true, capture: true });

  termEl.addEventListener('touchmove', (e) => {
    if (_touchStartY === null) return;
    const totalDy = _touchStartY - e.touches[0].clientY;
    const totalDx = _touchStartX - e.touches[0].clientX;

    // Cancel long-press if finger moved too far (#55)
    if (_longPressTimer) {
      const dx = e.touches[0].clientX - _longPressX;
      const dy = e.touches[0].clientY - _longPressY;
      if (Math.sqrt(dx * dx + dy * dy) > LONG_PRESS_MOVE_THRESHOLD) _cancelLongPress();
    }

    // Lock to vertical scroll once gesture is clearly more vertical than horizontal
    if (!_isTouchScroll && Math.abs(totalDy) > 12 && Math.abs(totalDy) > Math.abs(totalDx)) {
      _isTouchScroll = true;
    }

    if (_isTouchScroll && appState.terminal) {
      // Direct manipulation: compute where the finger IS relative to where it started,
      // then dispatch only the delta from where we've already scrolled to.
      // totalDy > 0 = finger went up = content should move up = newer content.
      // totalDy < 0 = finger went down = content should move down = older content.
      const cellH = Math.max(20, appState.terminal.options.fontSize * 1.5);
      const targetLines = Math.round(totalDy / cellH);
      const delta = targetLines - _scrolledLines;
      if (delta !== 0) {
        _scrolledLines = targetLines;
        const mouseMode = appState.terminal.modes && appState.terminal.modes.mouseTrackingMode;
        if (mouseMode && mouseMode !== 'none') {
          // delta > 0 (newer) → wheel down (65); delta < 0 (older) → wheel up (64).
          const btn = delta > 0 ? 65 : 64;
          const rect = termEl.getBoundingClientRect();
          const col = Math.max(1, Math.min(appState.terminal.cols,
            Math.floor((e.touches[0].clientX - rect.left) / (rect.width  / appState.terminal.cols)) + 1));
          const row = Math.max(1, Math.min(appState.terminal.rows,
            Math.floor((e.touches[0].clientY - rect.top)  / (rect.height / appState.terminal.rows)) + 1));
          const count = Math.abs(delta);
          if (_pendingSGR && _pendingSGR.btn === btn) {
            _pendingSGR.count += count;
          } else {
            _pendingSGR = { btn, col, row, count };
          }
        } else {
          _pendingLines += delta;
        }
        _scheduleScrollFlush();
      }
    }

    _lastTouchY = e.touches[0].clientY;
    _lastTouchX = e.touches[0].clientX;
  }, { passive: true, capture: true });

  termEl.addEventListener('touchend', () => {
    _cancelLongPress(); // (#55)
    const wasScroll = _isTouchScroll;
    // Measure total horizontal displacement for swipe-to-switch gesture (#16).
    const finalDx = (_lastTouchX ?? _touchStartX) - _touchStartX;
    const finalDy = (_lastTouchY ?? _touchStartY) - _touchStartY;

    _touchStartY = _touchStartX = _lastTouchY = _lastTouchX = null;
    _isTouchScroll = false;
    _scrolledLines = 0;
    _pendingLines = 0;
    _pendingSGR = null;
    if (_scrollRafId) { cancelAnimationFrame(_scrollRafId); _scrollRafId = null; }

    if (!wasScroll && !appState._selectionActive) {
      // Horizontal swipe: more than 40px X, dominant over Y → tmux window switch (#16).
      if (Math.abs(finalDx) > 40 && Math.abs(finalDx) > Math.abs(finalDy)) {
        // Swipe left (finalDx < 0) → previous window; swipe right → next window.
        sendSSHInput(finalDx < 0 ? '\x02p' : '\x02n');
      } else {
        setTimeout(focusIME, 50);
      }
    }
  }, { capture: true });
  } // end if (SWIPE_GESTURES)

  // ── Pinch-to-zoom → font size (#17) ──────────────────────────────────────
  // Two-finger pinch on the terminal adjusts xterm.js font size instead of
  // triggering browser zoom. Registered with { passive: false } so we can
  // call e.preventDefault() to block native pinch-zoom.
  // Guards on e.touches.length === 2 avoid conflict with single-touch paths.
  let _pinchStartDist = null;
  let _pinchStartSize = null;

  function _pinchDist(touches) {
    const dx = touches[0].clientX - touches[1].clientX;
    const dy = touches[0].clientY - touches[1].clientY;
    return Math.sqrt(dx * dx + dy * dy);
  }

  termEl.addEventListener('touchstart', (e) => {
    if (e.touches.length !== 2) return;
    _pinchStartDist = _pinchDist(e.touches);
    _pinchStartSize = appState.terminal
      ? appState.terminal.options.fontSize
      : (parseInt(localStorage.getItem('fontSize')) || 14);
    e.preventDefault();
  }, { passive: false });

  termEl.addEventListener('touchmove', (e) => {
    if (e.touches.length !== 2 || _pinchStartDist === null) return;
    e.preventDefault();
    const newSize = Math.round(_pinchStartSize * (_pinchDist(e.touches) / _pinchStartDist));
    applyFontSize(newSize);
  }, { passive: false });

  termEl.addEventListener('touchend', () => {
    _pinchStartDist = null;
    _pinchStartSize = null;
  });

  termEl.addEventListener('touchcancel', () => {
    _pinchStartDist = null;
    _pinchStartSize = null;
  });

  // ── Direct input (type="password") — char-by-char mode (#44/#48) ─────
  // Chrome/Gboard treats password fields as no-swipe, no-autocorrect inputs,
  // giving us the keyboard behaviour we want for direct/SSH-precise typing.
  const directEl = document.getElementById('directInput');

  directEl.addEventListener('input', () => {
    const text = directEl.value;
    directEl.value = '';
    if (!text) return;
    if (text === '\n') { sendSSHInput('\r'); return; }
    if (appState.ctrlActive) {
      const code = text[0].toLowerCase().charCodeAt(0) - 96;
      sendSSHInput(code >= 1 && code <= 26 ? String.fromCharCode(code) : text);
      setCtrlActive(false);
    } else {
      sendSSHInput(text);
    }
  });

  directEl.addEventListener('keydown', (e) => {
    if (e.ctrlKey && !e.altKey && e.key.length === 1) {
      const code = e.key.toLowerCase().charCodeAt(0) - 96;
      if (code >= 1 && code <= 26) {
        sendSSHInput(String.fromCharCode(code));
        e.preventDefault();
        return;
      }
    }
    if (KEY_MAP[e.key]) {
      sendSSHInput(KEY_MAP[e.key]);
      e.preventDefault();
      return;
    }
    if (e.key.length === 1 && !e.ctrlKey && !e.altKey && !e.metaKey) {
      if (appState.ctrlActive) {
        const code = e.key.toLowerCase().charCodeAt(0) - 96;
        sendSSHInput(code >= 1 && code <= 26 ? String.fromCharCode(code) : e.key);
        setCtrlActive(false);
      } else {
        sendSSHInput(e.key);
      }
      e.preventDefault();
      directEl.value = '';
    }
  });

}

// ─── UI chrome — extracted to modules/ui.js ──────────────────────────────────

