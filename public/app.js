import {
  getDefaultWsUrl, RECONNECT, KEY_REPEAT, THEMES, THEME_ORDER,
  ANSI, KEY_MAP, FONT_SIZE, SELECTION_OVERLAY,
} from './modules/constants.js';
import { appState } from './modules/state.js';
import { initRecording, startRecording, stopAndDownloadRecording } from './modules/recording.js';
import { initVault } from './modules/vault.js';
import {
  initProfiles, getProfiles, saveProfile, loadProfiles,
  loadProfileIntoForm, deleteProfile,
  getKeys, loadKeys, importKey, useKey, deleteKey,
  escHtml,
} from './modules/profiles.js';
import {
  initSettings, initSettingsPanel, registerServiceWorker,
  clearCacheAndReload,
} from './modules/settings.js';

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
    initIMEInput();
    initTabBar();
    initConnectForm();
    initTerminalActions();
    initKeyBar();         // #1 auto-hide + #2 IME toggle
    initRecording({ toast });
    initProfiles({ toast });
    initSettings({ toast, applyFontSize, applyTheme });
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

function focusIME() {
  // In direct mode, focus the password-type input — Chrome/Gboard disables
  // swipe-to-type and word autocorrect on password fields, giving true
  // char-by-char entry (#44/#48). In IME mode use the normal textarea.
  const id = appState.imeMode ? 'imeInput' : 'directInput';
  document.getElementById(id).focus({ preventScroll: true });
}

function sendSSHInput(data) {
  if (!appState.sshConnected || !appState.ws || appState.ws.readyState !== WebSocket.OPEN) return;
  appState.ws.send(JSON.stringify({ type: 'input', data }));
}

// ─── WebSocket / SSH connection ───────────────────────────────────────────────

function connect(profile) {
  appState.currentProfile = profile;
  appState.reconnectDelay = RECONNECT.INITIAL_DELAY_MS;
  cancelReconnect();
  _openWebSocket();
}

function _openWebSocket() {
  if (appState.ws) {
    appState.ws.onclose = null;
    appState.ws.close();
    appState.ws = null;
  }

  const wsUrl = localStorage.getItem('wsUrl') || getDefaultWsUrl();
  setStatus('connecting', `Connecting to ${wsUrl}…`);
  appState.terminal.writeln(ANSI.yellow(`Connecting to ${wsUrl}…`));

  try {
    appState.ws = new WebSocket(wsUrl);
  } catch (err) {
    appState.terminal.writeln(ANSI.red(`WebSocket error: ${err.message}`));
    scheduleReconnect();
    return;
  }

  appState.ws.onopen = () => {
    appState._wsConnected = true;
    startKeepAlive();
    const authMsg = {
      type: 'connect',
      host: appState.currentProfile.host,
      port: appState.currentProfile.port || 22,
      username: appState.currentProfile.username,
    };
    if (appState.currentProfile.authType === 'key' && appState.currentProfile.privateKey) {
      authMsg.privateKey = appState.currentProfile.privateKey;
      if (appState.currentProfile.passphrase) authMsg.passphrase = appState.currentProfile.passphrase;
    } else {
      authMsg.password = appState.currentProfile.password || '';
    }
    if (appState.currentProfile.initialCommand) authMsg.initialCommand = appState.currentProfile.initialCommand;
    if (localStorage.getItem('allowPrivateHosts') === 'true') authMsg.allowPrivate = true;
    appState.ws.send(JSON.stringify(authMsg));
    appState.terminal.writeln(ANSI.dim(`SSH → ${appState.currentProfile.username}@${appState.currentProfile.host}:${appState.currentProfile.port || 22}…`));
  };

  appState.ws.onmessage = (event) => {
    let msg;
    try { msg = JSON.parse(event.data); } catch (_) { return; }

    switch (msg.type) {
      case 'connected':
        appState.sshConnected = true;
        appState.reconnectDelay = RECONNECT.INITIAL_DELAY_MS;
        acquireWakeLock();
        // Reset terminal modes so stale mouse tracking from a previous session
        // doesn't cause scroll gestures to send SGR codes to a plain shell (#81)
        appState.terminal.reset();
        setStatus('connected', `${appState.currentProfile.username}@${appState.currentProfile.host}`);
        appState.terminal.writeln(ANSI.green('✓ Connected'));
        // Sync terminal size to server
        appState.ws.send(JSON.stringify({ type: 'resize', cols: appState.terminal.cols, rows: appState.terminal.rows }));
        // On every connect/reconnect: collapse nav chrome for continuous-feel (#36)
        appState.hasConnected = true;
        appState.tabBarVisible = false;
        _applyTabBarVisibility();
        focusIME();
        break;

      case 'output':
        appState.terminal.write(msg.data);
        if (appState.recording) {
          appState.recordingEvents.push([(Date.now() - appState.recordingStartTime) / 1000, 'o', msg.data]);
        }
        break;

      case 'error':
        appState.terminal.writeln(ANSI.red(`Error: ${msg.message}`));
        break;

      case 'disconnected':
        appState.sshConnected = false;
        setStatus('disconnected', 'Disconnected');
        appState.terminal.writeln(ANSI.yellow(`Disconnected: ${msg.reason || 'unknown reason'}`));
        stopAndDownloadRecording(); // auto-save appState.recording on SSH disconnect (#54)
        scheduleReconnect();
        break;

      case 'hostkey': { // SSH host key verification (#5)
        const hostKey = `${msg.host}:${msg.port}`;
        const knownHosts = JSON.parse(localStorage.getItem('knownHosts') || '{}');
        const known = knownHosts[hostKey];

        if (!known) {
          // First connect — prompt user to accept and store
          _showHostKeyPrompt(msg, null, (accepted) => {
            if (accepted) {
              knownHosts[hostKey] = { fingerprint: msg.fingerprint, keyType: msg.keyType, addedAt: new Date().toISOString() };
              localStorage.setItem('knownHosts', JSON.stringify(knownHosts));
            }
            appState.ws.send(JSON.stringify({ type: 'hostkey_response', accepted }));
          });
        } else if (known.fingerprint === msg.fingerprint) {
          // Fingerprint matches stored value — proceed silently
          appState.ws.send(JSON.stringify({ type: 'hostkey_response', accepted: true }));
        } else {
          // Fingerprint changed — block and warn (possible MITM)
          _showHostKeyPrompt(msg, known.fingerprint, (accepted) => {
            if (accepted) {
              const updated = JSON.parse(localStorage.getItem('knownHosts') || '{}');
              updated[hostKey] = { fingerprint: msg.fingerprint, keyType: msg.keyType, addedAt: new Date().toISOString() };
              localStorage.setItem('knownHosts', JSON.stringify(updated));
            }
            appState.ws.send(JSON.stringify({ type: 'hostkey_response', accepted }));
          });
        }
        break;
      }
    }
  };

  appState.ws.onclose = (event) => {
    appState._wsConnected = false;
    appState.sshConnected = false;
    stopKeepAlive();
    if (appState.currentProfile) {
      setStatus('disconnected', 'Disconnected');
      if (!event.wasClean) {
        appState.terminal.writeln(ANSI.red('Connection lost.'));
        scheduleReconnect();
      }
    }
  };

  appState.ws.onerror = () => {
    appState.terminal.writeln(ANSI.red('WebSocket error — check server URL in Settings.'));
  };
}

function scheduleReconnect() {
  if (!appState.currentProfile) return;

  const delaySec = Math.round(appState.reconnectDelay / 1000);
  appState.terminal.writeln(ANSI.dim(`Reconnecting in ${delaySec}s… (tap ✕ to cancel)`));
  setStatus('connecting', `Reconnecting in ${delaySec}s…`);

  appState.reconnectTimer = setTimeout(() => {
    appState.reconnectDelay = Math.min(
      appState.reconnectDelay * RECONNECT.BACKOFF_FACTOR,
      RECONNECT.MAX_DELAY_MS
    );
    _openWebSocket();
  }, appState.reconnectDelay);
}

function cancelReconnect() {
  if (appState.reconnectTimer) {
    clearTimeout(appState.reconnectTimer);
    appState.reconnectTimer = null;
  }
}

// Application-layer keepalive (#29): sends a ping every 25s so NAT/proxies don't
// drop idle SSH sessions. The server ignores unknown message types gracefully.
const WS_PING_INTERVAL_MS = 25_000;

function startKeepAlive() {
  stopKeepAlive();
  appState.keepAliveTimer = setInterval(() => {
    if (appState.ws && appState.ws.readyState === WebSocket.OPEN) {
      appState.ws.send(JSON.stringify({ type: 'ping' }));
    } else {
      stopKeepAlive();
    }
  }, WS_PING_INTERVAL_MS);
}

function stopKeepAlive() {
  if (appState.keepAliveTimer) {
    clearInterval(appState.keepAliveTimer);
    appState.keepAliveTimer = null;
  }
}

// ── Screen Wake Lock (#43) ────────────────────────────────────────────────────
// Prevents Chrome from throttling/killing the PWA while an SSH session is live.
// WakeLock is released automatically by the browser when the tab hides, so we
// reacquire it on visibilitychange → visible.
let _wakeLock = null;

async function acquireWakeLock() {
  if (!('wakeLock' in navigator)) return;
  try {
    _wakeLock = await navigator.wakeLock.request('screen');
  } catch (_) {} // denied (low battery, etc.) — fail silently
}

function releaseWakeLock() {
  if (_wakeLock) {
    _wakeLock.release().catch(() => {});
    _wakeLock = null;
  }
}

// visibilitychange: immediately reconnect if the session dropped while hidden,
// and reacquire the wake lock if a session is active.
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') {
    if (appState.sshConnected) acquireWakeLock();
    if (appState.currentProfile && (!appState.ws || appState.ws.readyState !== WebSocket.OPEN)) {
      cancelReconnect();
      _openWebSocket();
    }
  } else {
    releaseWakeLock(); // browser may do this automatically; belt-and-suspenders
  }
});

function disconnect() {
  stopAndDownloadRecording(); // auto-save any active appState.recording (#54)
  cancelReconnect();
  stopKeepAlive();
  releaseWakeLock();
  appState.currentProfile = null;
  appState.sshConnected = false;
  appState._wsConnected = false;

  if (appState.ws) {
    appState.ws.onclose = null;
    try { appState.ws.send(JSON.stringify({ type: 'disconnect' })); } catch (_) {}
    appState.ws.close();
    appState.ws = null;
  }

  setStatus('disconnected', 'Disconnected');
  appState.terminal.writeln(ANSI.yellow('Disconnected.'));
}

// Session recording (#54) — extracted to modules/recording.js

// ─── Status indicator ─────────────────────────────────────────────────────────

function setStatus(state, text) {
  // Keep session menu button in sync (#39)
  const btn = document.getElementById('sessionMenuBtn');
  if (btn) {
    btn.textContent = state === 'connected' ? text : 'MobiSSH';
    btn.classList.toggle('connected', state === 'connected');
  }
}

// ─── Session menu (#39) ───────────────────────────────────────────────────────

function initSessionMenu() {
  const menuBtn = document.getElementById('sessionMenuBtn');
  const menu    = document.getElementById('sessionMenu');

  // Sync session menu theme label with the active theme
  const initialTheme = THEMES[appState.activeThemeName];
  const themeBtn = document.getElementById('sessionThemeBtn');
  if (themeBtn && initialTheme) themeBtn.textContent = `Theme: ${initialTheme.label} ▸`;

  // Prevent focus theft only when the keyboard is already visible (#51).
  // If keyboard is dismissed, let focus move naturally so Android won't re-show it.
  menuBtn.addEventListener('mousedown', (e) => {
    if (keyboardVisible) e.preventDefault();
  });

  menuBtn.addEventListener('click', (e) => {
    e.stopPropagation();
    if (!appState.sshConnected) return; // no-op when not connected
    menu.classList.toggle('hidden');
  });

  function closeMenu() { menu.classList.add('hidden'); }

  // Font size +/− — menu stays open so user can tap repeatedly (#46)
  document.getElementById('fontDecBtn').addEventListener('click', (e) => {
    e.stopPropagation();
    applyFontSize((parseInt(localStorage.getItem('fontSize')) || 14) - 1);
  });
  document.getElementById('fontIncBtn').addEventListener('click', (e) => {
    e.stopPropagation();
    applyFontSize((parseInt(localStorage.getItem('fontSize')) || 14) + 1);
  });

  document.getElementById('sessionCopyBtn').addEventListener('click', () => {
    const sel = appState.terminal && appState.terminal.getSelection();
    if (sel) {
      navigator.clipboard.writeText(sel).then(() => toast('Copied')).catch(() => toast('Copy failed'));
    } else {
      toast('No text selected');
    }
    closeMenu();
  });

  document.getElementById('sessionResetBtn').addEventListener('click', () => {
    closeMenu();
    if (!appState.sshConnected) return;
    sendSSHInput('\x1bc');   // RIS — reset remote terminal state
    appState.terminal.reset();        // reset local xterm instance
  });

  document.getElementById('sessionClearBtn').addEventListener('click', () => {
    closeMenu();
    appState.terminal.clear();
  });

  document.getElementById('sessionRecordStartBtn').addEventListener('click', () => {
    closeMenu();
    startRecording();
  });

  document.getElementById('sessionRecordStopBtn').addEventListener('click', () => {
    closeMenu();
    stopAndDownloadRecording();
  });

  document.getElementById('sessionCtrlCBtn').addEventListener('click', () => {
    closeMenu();
    if (!appState.sshConnected) return;
    sendSSHInput('\x03');
  });

  document.getElementById('sessionCtrlZBtn').addEventListener('click', () => {
    closeMenu();
    if (!appState.sshConnected) return;
    sendSSHInput('\x1a');
  });

  document.getElementById('sessionReconnectBtn').addEventListener('click', () => {
    closeMenu();
    if (appState.currentProfile) _openWebSocket();
  });

  document.getElementById('sessionDisconnectBtn').addEventListener('click', () => {
    closeMenu();
    disconnect();
  });

  // Theme cycle — session-only (no localStorage write)
  document.getElementById('sessionThemeBtn').addEventListener('click', (e) => {
    e.stopPropagation();
    const idx = THEME_ORDER.indexOf(appState.activeThemeName);
    const next = THEME_ORDER[(idx + 1) % THEME_ORDER.length];
    applyTheme(next, { persist: false });
  });

  // Dismiss on outside tap
  document.addEventListener('click', () => menu.classList.add('hidden'));
}

// ─── Tab navigation ───────────────────────────────────────────────────────────

function initTabBar() {
  // Apply initial hidden state (terminal panel starts active, tab bar hidden)
  _applyTabBarVisibility();

  document.querySelectorAll('.tab').forEach((tab) => {
    tab.addEventListener('click', () => {
      const panelId = tab.dataset.panel;
      document.querySelectorAll('.tab').forEach((t) => t.classList.remove('active'));
      document.querySelectorAll('.panel').forEach((p) => p.classList.remove('active'));
      tab.classList.add('active');
      document.getElementById(`panel-${panelId}`).classList.add('active');

      if (panelId === 'terminal') {
        // Auto-hide tab bar when returning to terminal — but only once the
        // user has had at least one connection (#36: on cold start keep it visible)
        if (appState.hasConnected) {
          appState.tabBarVisible = false;
          _applyTabBarVisibility();
        }
        setTimeout(() => { appState.fitAddon.fit(); focusIME(); }, 50);
      } else {
        // Ensure tab bar stays visible on non-terminal panels
        appState.tabBarVisible = true;
        _applyTabBarVisibility();
      }
    });
  });
}

function _applyTabBarVisibility() {
  document.getElementById('tabBar').classList.toggle('hidden', !appState.tabBarVisible);
  // Keep --tab-height CSS var in sync for toast positioning
  document.documentElement.style.setProperty(
    '--tab-height',
    appState.tabBarVisible ? ROOT_CSS.tabHeight : '0px'
  );
}

function toggleTabBar() {
  appState.tabBarVisible = !appState.tabBarVisible;
  _applyTabBarVisibility();
  if (appState.fitAddon) appState.fitAddon.fit();
  if (appState.terminal) appState.terminal.scrollToBottom();
  if (appState.sshConnected && appState.ws && appState.ws.readyState === WebSocket.OPEN) {
    appState.ws.send(JSON.stringify({ type: 'resize', cols: appState.terminal.cols, rows: appState.terminal.rows }));
  }
}

function switchToTerminal() {
  document.querySelector('[data-panel="terminal"]').click();
}

// ─── Connect form ─────────────────────────────────────────────────────────────

function initConnectForm() {
  const form = document.getElementById('connectForm');
  const authType = document.getElementById('authType');

  authType.addEventListener('change', () => {
    const isKey = authType.value === 'key';
    document.getElementById('passwordGroup').style.display = isKey ? 'none' : 'block';
    document.getElementById('keyGroup').style.display = isKey ? 'block' : 'none';
  });

  form.addEventListener('submit', async (e) => {
    e.preventDefault();

    const profile = {
      name: document.getElementById('profileName').value.trim() || 'Server',
      host: document.getElementById('host').value.trim(),
      port: parseInt(document.getElementById('port').value) || 22,
      username: document.getElementById('username').value.trim(),
      authType: authType.value,
      password: document.getElementById('password').value,
      privateKey: document.getElementById('privateKey').value.trim(),
      passphrase: document.getElementById('passphrase').value,
      initialCommand: document.getElementById('initialCommand').value.trim(),
    };

    // Clear credential fields immediately — prevents Chrome password manager
    // from snapshotting the value before our vault stores it (#33)
    document.getElementById('password').value = '';
    document.getElementById('passphrase').value = '';

    await saveProfile(profile);
    switchToTerminal();
    connect(profile);
  });

  // Use stored key button
  document.getElementById('useStoredKeyBtn').addEventListener('click', () => {
    const keys = getKeys();
    if (!keys.length) { toast('No stored keys. Add one in the Keys tab.'); return; }

    // Show a simple picker (first key for now; future: modal)
    const key = keys[0];
    document.getElementById('privateKey').value = key.data;
    toast(`Using key: ${key.name}`);
  });
}

// ─── Key bar ──────────────────────────────────────────────────────────────────

function setCtrlActive(active) {
  appState.ctrlActive = active;
  document.getElementById('keyCtrl').classList.toggle('active', active);
}

// Attach a two-stage key-repeat handler to a key bar button (#89).
// onRepeat fires immediately on press, then again after KEY_REPEAT.DELAY_MS,
// then every KEY_REPEAT.INTERVAL_MS while held.
// onPress (optional) fires once on the initial press only (used for haptic feedback).
// e.preventDefault() on pointerdown suppresses the synthetic click event so the
// action isn't fired twice and the button doesn't steal IME focus.
function _attachRepeat(element, onRepeat, onPress) {
  let _delayTimer = null;
  let _intervalTimer = null;

  function _clear() {
    clearTimeout(_delayTimer);
    clearInterval(_intervalTimer);
    _delayTimer = _intervalTimer = null;
  }

  element.addEventListener('pointerdown', (e) => {
    e.preventDefault(); // suppress synthetic click; keeps IME input focused
    if (onPress) onPress();
    onRepeat();
    _delayTimer = setTimeout(() => {
      _intervalTimer = setInterval(onRepeat, KEY_REPEAT.INTERVAL_MS);
    }, KEY_REPEAT.DELAY_MS);
  });

  // Stop repeat and restore IME focus on release or pointer leaving the button
  element.addEventListener('pointerup',     () => { _clear(); setTimeout(focusIME, 50); });
  element.addEventListener('pointercancel', _clear);
  element.addEventListener('pointerleave',  _clear);

  // Suppress the long-press context menu on Android/iOS
  element.addEventListener('contextmenu', (e) => e.preventDefault());
}

function initTerminalActions() {
  document.getElementById('keyCtrl').addEventListener('click', () => {
    if (navigator.vibrate) navigator.vibrate(10);
    setCtrlActive(!appState.ctrlActive);
    focusIME();
  });

  const keys = {
    keyEsc:   '\x1b',
    keyTab:   '\t',
    keySlash: '/',
    keyPipe:  '|',
    keyDash:  '-',
    keyUp:    '\x1b[A',
    keyDown:  '\x1b[B',
    keyLeft:  '\x1b[D',
    keyRight: '\x1b[C',
    keyHome:  '\x1b[H',
    keyEnd:   '\x1b[F',
    keyPgUp:  '\x1b[5~',
    keyPgDn:  '\x1b[6~',
  };

  Object.entries(keys).forEach(([id, seq]) => {
    _attachRepeat(
      document.getElementById(id),
      () => sendSSHInput(seq),
      () => { if (navigator.vibrate) navigator.vibrate(10); },
    );
  });

  // Disconnect is now in the session menu (#39); no standalone button
}

// ─── Key bar visibility (#1) + IME/Direct mode (#2) ──────────────────────────

function initKeyBar() {
  appState.keyBarVisible = localStorage.getItem('keyBarVisible') !== 'false';
  appState.imeMode = localStorage.getItem('imeMode') !== 'direct';

  // Apply initial state without animation
  _applyKeyBarVisibility();
  _applyImeModeUI();

  // Right zone (chevron) toggles key bar; left zone (≡) toggles tab bar
  document.getElementById('handleChevron').addEventListener('click', toggleKeyBar);
  document.getElementById('tabBarToggleBtn').addEventListener('click', toggleTabBar);

  // IME/Direct mode toggle
  document.getElementById('keyModeBtn').addEventListener('click', () => {
    toggleImeMode();
    focusIME();
  });

}

function toggleKeyBar() {
  appState.keyBarVisible = !appState.keyBarVisible;
  localStorage.setItem('keyBarVisible', appState.keyBarVisible);
  _applyKeyBarVisibility();
  // Refit terminal after height change
  if (appState.fitAddon) appState.fitAddon.fit();
  if (appState.terminal) appState.terminal.scrollToBottom();
  if (appState.sshConnected && appState.ws && appState.ws.readyState === WebSocket.OPEN) {
    appState.ws.send(JSON.stringify({ type: 'resize', cols: appState.terminal.cols, rows: appState.terminal.rows }));
  }
}

function _applyKeyBarVisibility() {
  document.getElementById('key-bar').classList.toggle('hidden', !appState.keyBarVisible);
  document.getElementById('handleChevron').textContent = appState.keyBarVisible ? '▾' : '▴';
  // Keep --keybar-height CSS var in sync so toast positions correctly
  document.documentElement.style.setProperty(
    '--keybar-height',
    appState.keyBarVisible ? ROOT_CSS.keybarHeight : '0px'
  );
}

function toggleImeMode() {
  appState.imeMode = !appState.imeMode;
  localStorage.setItem('imeMode', appState.imeMode ? 'ime' : 'direct');
  _applyImeModeUI();
  focusIME(); // immediately switch focus to the appropriate input element
}

function _applyImeModeUI() {
  const btn = document.getElementById('keyModeBtn');
  btn.textContent = 'IME'; // label is always IME; colour signals state (#48)
  btn.classList.toggle('ime-active', appState.imeMode);
}

// ─── Utilities ────────────────────────────────────────────────────────────────

let toastTimer = null;
function toast(msg) {
  let el = document.getElementById('toast');
  if (!el) {
    el = document.createElement('div');
    el.id = 'toast';
    document.body.appendChild(el);
  }
  el.textContent = msg;
  el.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove('show'), 2500);
}

// ─── Host key verification prompt (#5) ───────────────────────────────────────
// Displays a blocking overlay asking the user to accept or reject the SSH host
// key fingerprint. On first connect knownFingerprint is null; on mismatch it
// contains the previously stored fingerprint.

function _showHostKeyPrompt(msg, knownFingerprint, callback) {
  // Remove stale overlay if present
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
        <code class="hostkey-val">${escHtml(msg.host)}:${msg.port}</code>
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

  function dismiss() { overlay.remove(); }

  overlay.querySelector('.hostkey-accept').addEventListener('click', () => { dismiss(); callback(true); });
  overlay.querySelector('.hostkey-reject').addEventListener('click', () => { dismiss(); callback(false); });
}
