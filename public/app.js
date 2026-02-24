'use strict';

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

// ─── Constants ───────────────────────────────────────────────────────────────

function getDefaultWsUrl() {
  // WebSocket bridge is served from the same origin as the frontend.
  // When deployed behind a reverse proxy at a subpath (e.g. /ssh), the server
  // injects <meta name="app-base-path"> so the WebSocket URL includes that prefix.
  const { protocol, host } = window.location;
  const wsProtocol = protocol === 'https:' ? 'wss:' : 'ws:';
  const basePath = document.querySelector('meta[name="app-base-path"]')?.content || '';
  return `${wsProtocol}//${host}${basePath}`;
}

const RECONNECT = {
  INITIAL_DELAY_MS: 2000,
  MAX_DELAY_MS: 30000,
  BACKOFF_FACTOR: 1.5,
};

// Key repeat timing for key bar buttons (#89)
const KEY_REPEAT = {
  DELAY_MS: 400,    // hold duration before first repeat (matches typical OS repeat delay)
  INTERVAL_MS: 80,  // interval between repeats (matches typical OS repeat rate)
};

// ─── Terminal themes (#47) ────────────────────────────────────────────────────

const THEMES = {
  dark: {
    label: 'Dark',
    theme: {
      background: '#000000',
      foreground: '#e0e0e0',
      cursor: '#00ff88',
      selectionBackground: '#00ff8844',
    },
  },
  light: {
    label: 'Light',
    theme: {
      background: '#ffffff',
      foreground: '#1a1a1a',
      cursor: '#0055cc',
      selectionBackground: '#0055cc44',
    },
  },
  solarizedDark: {
    label: 'Solarized Dark',
    theme: {
      background: '#002b36',
      foreground: '#839496',
      cursor: '#268bd2',
      selectionBackground: '#268bd244',
    },
  },
  solarizedLight: {
    label: 'Solarized Light',
    theme: {
      background: '#fdf6e3',
      foreground: '#657b83',
      cursor: '#268bd2',
      selectionBackground: '#268bd244',
    },
  },
  highContrast: {
    label: 'High Contrast',
    theme: {
      background: '#000000',
      foreground: '#ffffff',
      cursor: '#ffff00',
      selectionBackground: '#ffff0044',
    },
  },
};

const THEME_ORDER = ['dark', 'light', 'solarizedDark', 'solarizedLight', 'highContrast'];

// ANSI escape sequences for terminal colouring
const ANSI = {
  green: (s) => `\x1b[32m${s}\x1b[0m`,
  yellow: (s) => `\x1b[33m${s}\x1b[0m`,
  red: (s) => `\x1b[31m${s}\x1b[0m`,
  bold: (s) => `\x1b[1m${s}\x1b[0m`,
  dim: (s) => `\x1b[2m${s}\x1b[0m`,
};

// Terminal key map: DOM key name → VT sequence
const KEY_MAP = {
  Enter: '\r',
  Backspace: '\x7f',
  Tab: '\t',
  Escape: '\x1b',
  ArrowUp: '\x1b[A',
  ArrowDown: '\x1b[B',
  ArrowRight: '\x1b[C',
  ArrowLeft: '\x1b[D',
  Home: '\x1b[H',
  End: '\x1b[F',
  PageUp: '\x1b[5~',
  PageDown: '\x1b[6~',
  Delete: '\x1b[3~',
  Insert: '\x1b[2~',
  F1: '\x1bOP', F2: '\x1bOQ', F3: '\x1bOR', F4: '\x1bOS',
  F5: '\x1b[15~', F6: '\x1b[17~', F7: '\x1b[18~', F8: '\x1b[19~',
  F9: '\x1b[20~', F10: '\x1b[21~', F11: '\x1b[23~', F12: '\x1b[24~',
};

// ─── CSS layout constants (read from :root once; JS never hardcodes px values) ─

const ROOT_CSS = (() => {
  const s = getComputedStyle(document.documentElement);
  return {
    tabHeight:      s.getPropertyValue('--tab-height').trim(),
    keybarHeight:   s.getPropertyValue('--keybar-height').trim(),
  };
})();

// ─── State ───────────────────────────────────────────────────────────────────

let terminal = null;
let fitAddon = null;
let ws = null;
let _wsConnected = false;  // WebSocket open (tracked for future use)
let sshConnected = false;  // SSH session established
let currentProfile = null;
let reconnectTimer = null;
let reconnectDelay = RECONNECT.INITIAL_DELAY_MS;
let keepAliveTimer = null; // application-layer WS keepalive (#29)
let isComposing = false;   // IME composition in progress
let ctrlActive = false;    // sticky Ctrl modifier
let vaultKey = null;       // AES-GCM CryptoKey, null when locked
let vaultMethod = null;    // 'passwordcred' | 'webauthn-prf' | null
let keyBarVisible = true;  // key bar show/hide state (#1)
let imeMode = true;        // true = IME/swipe, false = direct char entry (#2)
let tabBarVisible = true;  // visible on cold start (#36); auto-hides after first connect
let hasConnected = false;  // true after first successful SSH session (#36)
let activeThemeName = 'dark'; // current terminal theme key (#47)
let _syncOverlayMetrics = null; // set by initIMEInput (#55)

// ─── Session recording state (#54) ───────────────────────────────────────────
let recording = false;          // true while a recording is in progress
let recordingStartTime = null;  // Date.now() at recording start (ms)
let recordingEvents = [];       // asciicast v2 output events: [elapsed_s, 'o', data]

// ─── Startup ─────────────────────────────────────────────────────────────────

document.addEventListener('DOMContentLoaded', () => {
  try {
    initTerminal();
    initIMEInput();
    initTabBar();
    initConnectForm();
    initTerminalActions();
    initKeyBar();         // #1 auto-hide + #2 IME toggle
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
  activeThemeName = THEMES[savedTheme] ? savedTheme : 'dark';

  const FONT_FAMILIES = {
    jetbrains: '"JetBrains Mono", monospace',
    firacode:  '"Fira Code", monospace',
    monospace: 'monospace',
  };
  const savedFont = localStorage.getItem('termFont') || 'jetbrains';
  const fontFamily = FONT_FAMILIES[savedFont] || FONT_FAMILIES.jetbrains;

  terminal = new Terminal({
    fontFamily,
    fontSize,
    theme: THEMES[activeThemeName].theme,
    cursorBlink: true,
    scrollback: 5000,
    convertEol: false,
    copyOnSelect: true,
  });

  fitAddon = new FitAddon.FitAddon();
  terminal.loadAddon(fitAddon);
  terminal.open(document.getElementById('terminal'));
  fitAddon.fit();

  // Re-measure character cells after web fonts finish loading (#71)
  document.fonts.ready.then(() => {
    terminal.options.fontFamily = fontFamily;
    fitAddon.fit();
  });

  window.addEventListener('resize', handleResize);

  // Show welcome banner
  terminal.writeln(ANSI.bold(ANSI.green('MobiSSH')));
  terminal.writeln(ANSI.dim('Tap terminal to activate keyboard  •  Use Connect tab to open a session'));
  terminal.writeln('');
}

function handleResize() {
  if (fitAddon) fitAddon.fit();
  if (sshConnected && ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({
      type: 'resize',
      cols: terminal.cols,
      rows: terminal.rows,
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

    // Refit terminal to the new dimensions
    if (fitAddon) fitAddon.fit();

    // Keep cursor visible — scroll to bottom after keyboard appears
    if (terminal) terminal.scrollToBottom();

    // Tell the server the terminal changed size
    if (sshConnected && ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'resize', cols: terminal.cols, rows: terminal.rows }));
    }
  }

  window.visualViewport.addEventListener('resize', onViewportChange);
}

const FONT_SIZE = { MIN: 8, MAX: 32 };

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
  if (terminal) {
    terminal.options.fontSize = size;
    if (fitAddon) fitAddon.fit();
    if (sshConnected && ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'resize', cols: terminal.cols, rows: terminal.rows }));
    }
    // Re-sync selection overlay metrics after font change (#55)
    if (typeof _syncOverlayMetrics === 'function') _syncOverlayMetrics();
  }
}

function applyTheme(name, { persist = false } = {}) {
  const t = THEMES[name];
  if (!t) return;
  activeThemeName = name;
  if (terminal) terminal.options.theme = t.theme;
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
    if (isComposing) {
      // Update preview with current composition text while the user is typing
      _imePreviewShow(ime.value || null);
      return;
    }
    const text = ime.value;
    ime.value = '';
    if (!text) return;
    // GBoard sends '\n' for Enter via input events — remap to '\r' for SSH
    if (text === '\n') { sendSSHInput('\r'); return; }
    if (ctrlActive) {
      const code = text[0].toLowerCase().charCodeAt(0) - 96;
      sendSSHInput(code >= 1 && code <= 26 ? String.fromCharCode(code) : text);
      setCtrlActive(false);
    } else {
      sendSSHInput(text);
    }
  });

  // ── IME composition (multi-step input methods, e.g. CJK, Gboard swipe) ─
  ime.addEventListener('compositionstart', () => {
    isComposing = true;
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
    isComposing = false;
    _imePreviewShow(null); // hide preview on commit
    // Prefer ime.value (full accumulated phrase) over e.data, which on Android
    // voice dictation is often "" or only the last recognised word.
    const text = ime.value || e.data;
    ime.value = '';
    if (!text) return;
    if (text === '\n') { sendSSHInput('\r'); return; }
    if (ctrlActive) {
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
    isComposing = false;
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
    if (!imeMode && e.key.length === 1 && !e.ctrlKey && !e.altKey && !e.metaKey) {
      if (ctrlActive) {
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
  let _selectionActive = false;
  let _overlayCellH = 0; // cached cell height from last metric sync

  // URL regex — matches http/https URLs, strips common trailing punctuation
  const URL_RE = /https?:\/\/[^\s<>"')\]]+/g;
  function _stripTrailingPunct(url) {
    return url.replace(/[.,;:!?)]+$/, '');
  }

  // Compute and apply font metrics so overlay lines align with canvas cells
  _syncOverlayMetrics = function _syncOverlayMetricsFn() {
    if (!terminal || !selOverlay) return;
    const screen = document.querySelector('.xterm-screen');
    if (!screen) return;
    const cellH = screen.offsetHeight / terminal.rows;
    const cellW = screen.offsetWidth / terminal.cols;
    _overlayCellH = cellH;
    selOverlay.style.fontFamily = terminal.options.fontFamily;
    selOverlay.style.fontSize = terminal.options.fontSize + 'px';
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
    testSpan.style.font = terminal.options.fontSize + 'px ' + terminal.options.fontFamily;
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
    if (!terminal || !selOverlay) return;
    _syncOverlayMetrics();
    const buf = terminal.buffer.active;
    const startLine = buf.viewportY;
    const frag = document.createDocumentFragment();
    for (let i = 0; i < terminal.rows; i++) {
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
    if (_selectionActive) return;
    _selectionActive = true;
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
    _selectionActive = false;
    selOverlay.classList.remove('active');
    selOverlay.innerHTML = ''; // clear stale content (URL underlines etc.)
    selBar.classList.add('hidden');
    window.getSelection().removeAllRanges();
    // Re-focus IME so keyboard stays available
    setTimeout(focusIME, 50);
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
    if (!_selectionActive) return;
    _updateSelBar();
    // Auto-dismiss if selection is cleared
    const sel = window.getSelection();
    if (!sel.toString()) {
      // Small delay — selection can briefly be empty during handle drag
      setTimeout(() => {
        if (_selectionActive && !window.getSelection().toString()) {
          exitSelectionMode();
        }
      }, 300);
    }
  });

  // URL tap handler — when in selection mode, tapping a URL auto-selects it
  selOverlay.addEventListener('click', (e) => {
    if (!_selectionActive) return;
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

  // Suppress browser's useless "Paste" context menu on terminal long-press (#55)
  termEl.addEventListener('contextmenu', (e) => e.preventDefault());

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
    if (_pendingLines !== 0 && terminal) {
      terminal.scrollLines(_pendingLines);
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
    if (e.touches.length === 1 && !_selectionActive) {
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

    if (_isTouchScroll && terminal) {
      // Direct manipulation: compute where the finger IS relative to where it started,
      // then dispatch only the delta from where we've already scrolled to.
      // totalDy > 0 = finger went up = content should move up = newer content.
      // totalDy < 0 = finger went down = content should move down = older content.
      const cellH = Math.max(20, terminal.options.fontSize * 1.5);
      const targetLines = Math.round(totalDy / cellH);
      const delta = targetLines - _scrolledLines;
      if (delta !== 0) {
        _scrolledLines = targetLines;
        const mouseMode = terminal.modes && terminal.modes.mouseTrackingMode;
        if (mouseMode && mouseMode !== 'none') {
          // delta > 0 (newer) → wheel down (65); delta < 0 (older) → wheel up (64).
          const btn = delta > 0 ? 65 : 64;
          const rect = termEl.getBoundingClientRect();
          const col = Math.max(1, Math.min(terminal.cols,
            Math.floor((e.touches[0].clientX - rect.left) / (rect.width  / terminal.cols)) + 1));
          const row = Math.max(1, Math.min(terminal.rows,
            Math.floor((e.touches[0].clientY - rect.top)  / (rect.height / terminal.rows)) + 1));
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

    if (!wasScroll && !_selectionActive) {
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
    _pinchStartSize = terminal
      ? terminal.options.fontSize
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
    if (ctrlActive) {
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
      if (ctrlActive) {
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
  const id = imeMode ? 'imeInput' : 'directInput';
  document.getElementById(id).focus({ preventScroll: true });
}

function sendSSHInput(data) {
  if (!sshConnected || !ws || ws.readyState !== WebSocket.OPEN) return;
  ws.send(JSON.stringify({ type: 'input', data }));
}

// ─── WebSocket / SSH connection ───────────────────────────────────────────────

function connect(profile) {
  currentProfile = profile;
  reconnectDelay = RECONNECT.INITIAL_DELAY_MS;
  cancelReconnect();
  _openWebSocket();
}

function _openWebSocket() {
  if (ws) {
    ws.onclose = null;
    ws.close();
    ws = null;
  }

  const wsUrl = localStorage.getItem('wsUrl') || getDefaultWsUrl();
  setStatus('connecting', `Connecting to ${wsUrl}…`);
  terminal.writeln(ANSI.yellow(`Connecting to ${wsUrl}…`));

  try {
    ws = new WebSocket(wsUrl);
  } catch (err) {
    terminal.writeln(ANSI.red(`WebSocket error: ${err.message}`));
    scheduleReconnect();
    return;
  }

  ws.onopen = () => {
    _wsConnected = true;
    startKeepAlive();
    const authMsg = {
      type: 'connect',
      host: currentProfile.host,
      port: currentProfile.port || 22,
      username: currentProfile.username,
    };
    if (currentProfile.authType === 'key' && currentProfile.privateKey) {
      authMsg.privateKey = currentProfile.privateKey;
      if (currentProfile.passphrase) authMsg.passphrase = currentProfile.passphrase;
    } else {
      authMsg.password = currentProfile.password || '';
    }
    if (currentProfile.initialCommand) authMsg.initialCommand = currentProfile.initialCommand;
    if (localStorage.getItem('allowPrivateHosts') === 'true') authMsg.allowPrivate = true;
    ws.send(JSON.stringify(authMsg));
    terminal.writeln(ANSI.dim(`SSH → ${currentProfile.username}@${currentProfile.host}:${currentProfile.port || 22}…`));
  };

  ws.onmessage = (event) => {
    let msg;
    try { msg = JSON.parse(event.data); } catch (_) { return; }

    switch (msg.type) {
      case 'connected':
        sshConnected = true;
        reconnectDelay = RECONNECT.INITIAL_DELAY_MS;
        acquireWakeLock();
        // Reset terminal modes so stale mouse tracking from a previous session
        // doesn't cause scroll gestures to send SGR codes to a plain shell (#81)
        terminal.reset();
        setStatus('connected', `${currentProfile.username}@${currentProfile.host}`);
        terminal.writeln(ANSI.green('✓ Connected'));
        // Sync terminal size to server
        ws.send(JSON.stringify({ type: 'resize', cols: terminal.cols, rows: terminal.rows }));
        // On every connect/reconnect: collapse nav chrome for continuous-feel (#36)
        hasConnected = true;
        tabBarVisible = false;
        _applyTabBarVisibility();
        focusIME();
        break;

      case 'output':
        terminal.write(msg.data);
        if (recording) {
          recordingEvents.push([(Date.now() - recordingStartTime) / 1000, 'o', msg.data]);
        }
        break;

      case 'error':
        terminal.writeln(ANSI.red(`Error: ${msg.message}`));
        break;

      case 'disconnected':
        sshConnected = false;
        setStatus('disconnected', 'Disconnected');
        terminal.writeln(ANSI.yellow(`Disconnected: ${msg.reason || 'unknown reason'}`));
        stopAndDownloadRecording(); // auto-save recording on SSH disconnect (#54)
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
            ws.send(JSON.stringify({ type: 'hostkey_response', accepted }));
          });
        } else if (known.fingerprint === msg.fingerprint) {
          // Fingerprint matches stored value — proceed silently
          ws.send(JSON.stringify({ type: 'hostkey_response', accepted: true }));
        } else {
          // Fingerprint changed — block and warn (possible MITM)
          _showHostKeyPrompt(msg, known.fingerprint, (accepted) => {
            if (accepted) {
              const updated = JSON.parse(localStorage.getItem('knownHosts') || '{}');
              updated[hostKey] = { fingerprint: msg.fingerprint, keyType: msg.keyType, addedAt: new Date().toISOString() };
              localStorage.setItem('knownHosts', JSON.stringify(updated));
            }
            ws.send(JSON.stringify({ type: 'hostkey_response', accepted }));
          });
        }
        break;
      }
    }
  };

  ws.onclose = (event) => {
    _wsConnected = false;
    sshConnected = false;
    stopKeepAlive();
    if (currentProfile) {
      setStatus('disconnected', 'Disconnected');
      if (!event.wasClean) {
        terminal.writeln(ANSI.red('Connection lost.'));
        scheduleReconnect();
      }
    }
  };

  ws.onerror = () => {
    terminal.writeln(ANSI.red('WebSocket error — check server URL in Settings.'));
  };
}

function scheduleReconnect() {
  if (!currentProfile) return;

  const delaySec = Math.round(reconnectDelay / 1000);
  terminal.writeln(ANSI.dim(`Reconnecting in ${delaySec}s… (tap ✕ to cancel)`));
  setStatus('connecting', `Reconnecting in ${delaySec}s…`);

  reconnectTimer = setTimeout(() => {
    reconnectDelay = Math.min(
      reconnectDelay * RECONNECT.BACKOFF_FACTOR,
      RECONNECT.MAX_DELAY_MS
    );
    _openWebSocket();
  }, reconnectDelay);
}

function cancelReconnect() {
  if (reconnectTimer) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }
}

// Application-layer keepalive (#29): sends a ping every 25s so NAT/proxies don't
// drop idle SSH sessions. The server ignores unknown message types gracefully.
const WS_PING_INTERVAL_MS = 25_000;

function startKeepAlive() {
  stopKeepAlive();
  keepAliveTimer = setInterval(() => {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'ping' }));
    } else {
      stopKeepAlive();
    }
  }, WS_PING_INTERVAL_MS);
}

function stopKeepAlive() {
  if (keepAliveTimer) {
    clearInterval(keepAliveTimer);
    keepAliveTimer = null;
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
    if (sshConnected) acquireWakeLock();
    if (currentProfile && (!ws || ws.readyState !== WebSocket.OPEN)) {
      cancelReconnect();
      _openWebSocket();
    }
  } else {
    releaseWakeLock(); // browser may do this automatically; belt-and-suspenders
  }
});

function disconnect() {
  stopAndDownloadRecording(); // auto-save any active recording (#54)
  cancelReconnect();
  stopKeepAlive();
  releaseWakeLock();
  currentProfile = null;
  sshConnected = false;
  _wsConnected = false;

  if (ws) {
    ws.onclose = null;
    try { ws.send(JSON.stringify({ type: 'disconnect' })); } catch (_) {}
    ws.close();
    ws = null;
  }

  setStatus('disconnected', 'Disconnected');
  terminal.writeln(ANSI.yellow('Disconnected.'));
}

// ─── Session recording (#54) ──────────────────────────────────────────────────
// asciicast v2 format: https://github.com/asciinema/asciinema/blob/master/doc/asciicast-v2.md
// Header line: JSON object with version, width, height, timestamp, title
// Event lines: JSON array [elapsed_seconds, "o", data]

function startRecording() {
  if (recording) return;
  recording = true;
  recordingStartTime = Date.now();
  recordingEvents = [];
  _updateRecordingUI();
  toast('Recording started');
}

function stopAndDownloadRecording() {
  if (!recording) return;
  recording = false;
  _downloadCastFile();
  _updateRecordingUI();
}

function _downloadCastFile() {
  const header = JSON.stringify({
    version: 2,
    width: terminal ? terminal.cols : 220,
    height: terminal ? terminal.rows : 50,
    timestamp: Math.floor(recordingStartTime / 1000),
    title: currentProfile
      ? `${currentProfile.username}@${currentProfile.host}:${currentProfile.port || 22}`
      : 'MobiSSH Session',
  });
  const lines = [header, ...recordingEvents.map((e) => JSON.stringify(e))].join('\n');
  const blob = new Blob([lines + '\n'], { type: 'text/plain' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  // Filename: mobissh-YYYY-MM-DDTHH-MM-SS.cast
  const ts = new Date(recordingStartTime)
    .toISOString()
    .replace(/[:.]/g, '-')
    .slice(0, 19);
  a.download = `mobissh-${ts}.cast`;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
  recordingEvents = [];
  recordingStartTime = null;
}

function _updateRecordingUI() {
  const startBtn = document.getElementById('sessionRecordStartBtn');
  const stopBtn  = document.getElementById('sessionRecordStopBtn');
  if (!startBtn || !stopBtn) return;
  startBtn.classList.toggle('hidden', recording);
  stopBtn.classList.toggle('hidden', !recording);
}

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
  const initialTheme = THEMES[activeThemeName];
  const themeBtn = document.getElementById('sessionThemeBtn');
  if (themeBtn && initialTheme) themeBtn.textContent = `Theme: ${initialTheme.label} ▸`;

  // Prevent focus theft only when the keyboard is already visible (#51).
  // If keyboard is dismissed, let focus move naturally so Android won't re-show it.
  menuBtn.addEventListener('mousedown', (e) => {
    if (keyboardVisible) e.preventDefault();
  });

  menuBtn.addEventListener('click', (e) => {
    e.stopPropagation();
    if (!sshConnected) return; // no-op when not connected
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
    const sel = terminal && terminal.getSelection();
    if (sel) {
      navigator.clipboard.writeText(sel).then(() => toast('Copied')).catch(() => toast('Copy failed'));
    } else {
      toast('No text selected');
    }
    closeMenu();
  });

  document.getElementById('sessionResetBtn').addEventListener('click', () => {
    closeMenu();
    if (!sshConnected) return;
    sendSSHInput('\x1bc');   // RIS — reset remote terminal state
    terminal.reset();        // reset local xterm instance
  });

  document.getElementById('sessionClearBtn').addEventListener('click', () => {
    closeMenu();
    terminal.clear();
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
    if (!sshConnected) return;
    sendSSHInput('\x03');
  });

  document.getElementById('sessionCtrlZBtn').addEventListener('click', () => {
    closeMenu();
    if (!sshConnected) return;
    sendSSHInput('\x1a');
  });

  document.getElementById('sessionReconnectBtn').addEventListener('click', () => {
    closeMenu();
    if (currentProfile) _openWebSocket();
  });

  document.getElementById('sessionDisconnectBtn').addEventListener('click', () => {
    closeMenu();
    disconnect();
  });

  // Theme cycle — session-only (no localStorage write)
  document.getElementById('sessionThemeBtn').addEventListener('click', (e) => {
    e.stopPropagation();
    const idx = THEME_ORDER.indexOf(activeThemeName);
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
        if (hasConnected) {
          tabBarVisible = false;
          _applyTabBarVisibility();
        }
        setTimeout(() => { fitAddon.fit(); focusIME(); }, 50);
      } else {
        // Ensure tab bar stays visible on non-terminal panels
        tabBarVisible = true;
        _applyTabBarVisibility();
      }
    });
  });
}

function _applyTabBarVisibility() {
  document.getElementById('tabBar').classList.toggle('hidden', !tabBarVisible);
  // Keep --tab-height CSS var in sync for toast positioning
  document.documentElement.style.setProperty(
    '--tab-height',
    tabBarVisible ? ROOT_CSS.tabHeight : '0px'
  );
}

function toggleTabBar() {
  tabBarVisible = !tabBarVisible;
  _applyTabBarVisibility();
  if (fitAddon) fitAddon.fit();
  if (terminal) terminal.scrollToBottom();
  if (sshConnected && ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ type: 'resize', cols: terminal.cols, rows: terminal.rows }));
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
  ctrlActive = active;
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
    setCtrlActive(!ctrlActive);
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
  keyBarVisible = localStorage.getItem('keyBarVisible') !== 'false';
  imeMode = localStorage.getItem('imeMode') !== 'direct';

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
  keyBarVisible = !keyBarVisible;
  localStorage.setItem('keyBarVisible', keyBarVisible);
  _applyKeyBarVisibility();
  // Refit terminal after height change
  if (fitAddon) fitAddon.fit();
  if (terminal) terminal.scrollToBottom();
  if (sshConnected && ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ type: 'resize', cols: terminal.cols, rows: terminal.rows }));
  }
}

function _applyKeyBarVisibility() {
  document.getElementById('key-bar').classList.toggle('hidden', !keyBarVisible);
  document.getElementById('handleChevron').textContent = keyBarVisible ? '▾' : '▴';
  // Keep --keybar-height CSS var in sync so toast positions correctly
  document.documentElement.style.setProperty(
    '--keybar-height',
    keyBarVisible ? ROOT_CSS.keybarHeight : '0px'
  );
}

function toggleImeMode() {
  imeMode = !imeMode;
  localStorage.setItem('imeMode', imeMode ? 'ime' : 'direct');
  _applyImeModeUI();
  focusIME(); // immediately switch focus to the appropriate input element
}

function _applyImeModeUI() {
  const btn = document.getElementById('keyModeBtn');
  btn.textContent = 'IME'; // label is always IME; colour signals state (#48)
  btn.classList.toggle('ime-active', imeMode);
}

// ─── Vault ────────────────────────────────────────────────────────────────────
// Credentials are AES-GCM encrypted at rest. The vault key is derived from one
// of two sources, depending on browser support:
//   1. PasswordCredential (Chrome/Android) — random 32-byte key in credential store
//   2. WebAuthn PRF (#14, Safari 18+/iOS 18+) — key derived from passkey + biometric
// If neither is available, credentials are not saved (never stored in plaintext).

const VAULT_CRED_ID = 'ssh-pwa-vault';

function _b64(bytes) {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}
function _bytes(b64) {
  return Uint8Array.from(atob(b64), c => c.charCodeAt(0));
}

// Detect which vault key derivation method this browser supports.
// PasswordCredential (Chrome/Android) > WebAuthn PRF (Safari 18+/iOS 18+) > null
function _detectVaultMethod() {
  if (window.PasswordCredential && 'credentials' in navigator) return 'passwordcred';
  if (window.PublicKeyCredential && 'credentials' in navigator) return 'webauthn-prf';
  return null;
}

// ─── WebAuthn PRF helpers (#14) ──────────────────────────────────────────────
// On browsers without PasswordCredential (iOS Safari), derive the vault AES key
// from a passkey via the WebAuthn PRF extension. Requires iOS 18+ / Safari 18+.

function _webauthnHasRegistration() {
  return !!(localStorage.getItem('webauthnCredId') && localStorage.getItem('webauthnPrfSalt'));
}

async function _webauthnRegister() {
  const salt = crypto.getRandomValues(new Uint8Array(32));
  const userId = crypto.getRandomValues(new Uint8Array(16));
  try {
    const credential = await navigator.credentials.create({
      publicKey: {
        rp: { name: 'MobiSSH', id: location.hostname },
        user: { id: userId, name: 'MobiSSH Vault', displayName: 'MobiSSH Vault' },
        challenge: crypto.getRandomValues(new Uint8Array(32)),
        pubKeyCredParams: [
          { type: 'public-key', alg: -7 },
          { type: 'public-key', alg: -257 },
        ],
        authenticatorSelection: {
          authenticatorAttachment: 'platform',
          residentKey: 'preferred',
          userVerification: 'required',
        },
        extensions: { prf: {} },
      },
    });
    const ext = credential.getClientExtensionResults();
    if (!ext.prf || !ext.prf.enabled) return false;
    localStorage.setItem('webauthnCredId', _b64(new Uint8Array(credential.rawId)));
    localStorage.setItem('webauthnPrfSalt', _b64(salt));
    return _webauthnDerive('required');
  } catch (_) { return false; }
}

async function _webauthnDerive(mediation) {
  const credIdB64 = localStorage.getItem('webauthnCredId');
  const saltB64 = localStorage.getItem('webauthnPrfSalt');
  if (!credIdB64 || !saltB64) return false;
  const credId = _bytes(credIdB64);
  const salt = _bytes(saltB64);
  try {
    const assertion = await navigator.credentials.get({
      publicKey: {
        challenge: crypto.getRandomValues(new Uint8Array(32)),
        rpId: location.hostname,
        allowCredentials: [{ type: 'public-key', id: credId.buffer }],
        userVerification: 'required',
        extensions: { prf: { eval: { first: salt.buffer } } },
      },
      mediation,
    });
    const ext = assertion.getClientExtensionResults();
    if (!ext.prf || !ext.prf.results || !ext.prf.results.first) return false;
    const keyBytes = new Uint8Array(ext.prf.results.first);
    vaultKey = await crypto.subtle.importKey(
      'raw', keyBytes, { name: 'AES-GCM' }, false, ['encrypt', 'decrypt']
    );
    return true;
  } catch (_) { return false; }
}

// ─── Vault lifecycle ─────────────────────────────────────────────────────────

async function initVault() {
  vaultMethod = _detectVaultMethod();
  if (!vaultMethod) return;
  const vault = JSON.parse(localStorage.getItem('sshVault') || '{}');
  if (!Object.keys(vault).length) return;
  await _tryUnlockVault('silent');
}

async function _tryUnlockVault(mediation) {
  if (vaultMethod === 'passwordcred') {
    try {
      const cred = await navigator.credentials.get({ password: true, mediation });
      if (cred && cred.password) {
        const keyBytes = _bytes(cred.password);
        vaultKey = await crypto.subtle.importKey(
          'raw', keyBytes, { name: 'AES-GCM' }, false, ['encrypt', 'decrypt']
        );
        return true;
      }
    } catch (_) {}
    return false;
  }
  if (vaultMethod === 'webauthn-prf') {
    if (!_webauthnHasRegistration()) return false;
    return _webauthnDerive(mediation);
  }
  return false;
}

async function _ensureVaultKey() {
  if (vaultKey) return true;
  if (vaultMethod === 'passwordcred') {
    try {
      const keyBytes = crypto.getRandomValues(new Uint8Array(32));
      const rawKey = _b64(keyBytes);
      const cred = new PasswordCredential({ id: VAULT_CRED_ID, password: rawKey, name: 'SSH PWA' });
      await navigator.credentials.store(cred);
      vaultKey = await crypto.subtle.importKey(
        'raw', keyBytes, { name: 'AES-GCM' }, false, ['encrypt', 'decrypt']
      );
      return true;
    } catch (_) { return false; }
  }
  if (vaultMethod === 'webauthn-prf') {
    if (_webauthnHasRegistration()) return _webauthnDerive('required');
    return _webauthnRegister();
  }
  return false;
}

async function _vaultStore(vaultId, data) {
  if (!vaultKey) return;
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv }, vaultKey,
    new TextEncoder().encode(JSON.stringify(data))
  );
  const vault = JSON.parse(localStorage.getItem('sshVault') || '{}');
  vault[vaultId] = { iv: _b64(iv), ct: _b64(new Uint8Array(ct)) };
  localStorage.setItem('sshVault', JSON.stringify(vault));
}

async function _vaultLoad(vaultId) {
  if (!vaultKey) return null;
  const vault = JSON.parse(localStorage.getItem('sshVault') || '{}');
  const entry = vault[vaultId];
  if (!entry) return null;
  try {
    const plain = await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: _bytes(entry.iv) }, vaultKey, _bytes(entry.ct)
    );
    return JSON.parse(new TextDecoder().decode(plain));
  } catch (_) { return null; }
}

function _vaultDelete(vaultId) {
  const vault = JSON.parse(localStorage.getItem('sshVault') || '{}');
  delete vault[vaultId];
  localStorage.setItem('sshVault', JSON.stringify(vault));
}

// ─── Profile storage ──────────────────────────────────────────────────────────

function getProfiles() {
  return JSON.parse(localStorage.getItem('sshProfiles') || '[]');
}

async function saveProfile(profile) {
  const profiles = getProfiles();

  // Update existing profile if same host+port+username, otherwise add new
  const existingIdx = profiles.findIndex(
    (p) => p.host === profile.host &&
           String(p.port || 22) === String(profile.port || 22) &&
           p.username === profile.username
  );

  const vaultId = existingIdx >= 0
    ? (profiles[existingIdx].vaultId || (crypto.randomUUID ? crypto.randomUUID() : Math.random().toString(36).slice(2)))
    : (crypto.randomUUID ? crypto.randomUUID() : Math.random().toString(36).slice(2));

  const saved = {
    name: profile.name,
    host: profile.host,
    port: profile.port,
    username: profile.username,
    authType: profile.authType,
    initialCommand: profile.initialCommand || '',
    vaultId,
  };

  // Store credentials in encrypted vault only — never plaintext (#68)
  const creds = {};
  if (profile.password)   creds.password   = profile.password;
  if (profile.privateKey) creds.privateKey = profile.privateKey;
  if (profile.passphrase) creds.passphrase = profile.passphrase;

  const hasVault = await _ensureVaultKey();
  if (hasVault && Object.keys(creds).length) {
    await _vaultStore(vaultId, creds);
    saved.hasVaultCreds = true;
  } else if (!hasVault && Object.keys(creds).length) {
    // Vault unavailable (iOS Safari, Firefox) — credentials NOT saved.
    // Profile metadata is still saved so the user doesn't have to re-enter
    // host/port/username, but they'll need to enter the password each time.
    toast('Credentials not saved — vault unavailable on this browser.');
  }

  if (existingIdx >= 0) {
    profiles[existingIdx] = saved;
  } else {
    profiles.push(saved);
  }
  localStorage.setItem('sshProfiles', JSON.stringify(profiles));
  loadProfiles();
}

function loadProfiles() {
  const profiles = getProfiles();
  const list = document.getElementById('profileList');

  if (!profiles.length) {
    list.innerHTML = '<p class="empty-hint">No saved profiles yet.</p>';
    return;
  }

  list.innerHTML = profiles.map((p, i) => `
    <div class="profile-item" data-idx="${i}">
      <span class="profile-name">${escHtml(p.name)}${p.hasVaultCreds ? ' <span class="vault-badge">saved</span>' : ''}</span>
      <span class="profile-host">${escHtml(p.username)}@${escHtml(p.host)}:${p.port || 22}</span>
      <div class="item-actions">
        <button class="item-btn" data-action="edit" data-idx="${i}">✎ Edit</button>
        <button class="item-btn danger" data-action="delete" data-idx="${i}">Delete</button>
      </div>
    </div>
  `).join('');
}

async function loadProfileIntoForm(idx) {
  const profile = getProfiles()[idx];
  if (!profile) return;

  document.getElementById('profileName').value = profile.name || '';
  document.getElementById('host').value = profile.host || '';
  document.getElementById('port').value = profile.port || 22;
  document.getElementById('username').value = profile.username || '';

  const authTypeEl = document.getElementById('authType');
  authTypeEl.value = profile.authType || 'password';
  authTypeEl.dispatchEvent(new Event('change'));

  document.getElementById('password').value = '';
  document.getElementById('privateKey').value = '';
  document.getElementById('passphrase').value = '';
  document.getElementById('initialCommand').value = profile.initialCommand || '';

  if (profile.vaultId && profile.hasVaultCreds) {
    // If vault is locked, explicitly prompt biometric now
    if (!vaultKey) await _tryUnlockVault('required');
    const creds = await _vaultLoad(profile.vaultId);
    if (creds) {
      if (creds.password)   document.getElementById('password').value   = creds.password;
      if (creds.privateKey) document.getElementById('privateKey').value = creds.privateKey;
      if (creds.passphrase) document.getElementById('passphrase').value = creds.passphrase;
      toast('Credentials unlocked');
    } else {
      toast('Vault locked — enter credentials manually');
    }
  } else if (!profile.hasVaultCreds) {
    // No vault credentials — user must enter them manually (iOS/Firefox)
    toast('Enter credentials — not saved on this browser.');
  }

  document.querySelector('[data-panel="connect"]').click();
}

function deleteProfile(idx) {
  const profiles = getProfiles();
  const p = profiles[idx];
  if (p && p.vaultId) _vaultDelete(p.vaultId);
  profiles.splice(idx, 1);
  localStorage.setItem('sshProfiles', JSON.stringify(profiles));
  loadProfiles();
}

// ─── Key storage ──────────────────────────────────────────────────────────────

function getKeys() {
  return JSON.parse(localStorage.getItem('sshKeys') || '[]');
}

function loadKeys() {
  const keys = getKeys();
  const list = document.getElementById('keyList');

  if (!keys.length) {
    list.innerHTML = '<p class="empty-hint">No keys stored.</p>';
    return;
  }

  list.innerHTML = keys.map((k, i) => `
    <div class="key-item">
      <span class="key-name">${escHtml(k.name)}</span>
      <span class="key-created">Added ${new Date(k.created).toLocaleDateString()}</span>
      <div class="item-actions">
        <button class="item-btn" data-action="use" data-idx="${i}">Use in form</button>
        <button class="item-btn danger" data-action="delete" data-idx="${i}">Delete</button>
      </div>
    </div>
  `).join('');
}

document.addEventListener('DOMContentLoaded', () => {
  document.getElementById('importKeyBtn').addEventListener('click', async () => {
    const name = document.getElementById('keyName').value.trim();
    const data = document.getElementById('keyData').value.trim();
    if (!name || !data) { toast('Name and key data are required.'); return; }
    if (!data.includes('PRIVATE KEY')) { toast('Does not look like a PEM private key.'); return; }

    const hasVault = await _ensureVaultKey();
    if (!hasVault) { toast('Key not saved — vault unavailable on this browser.'); return; }

    const vaultId = crypto.randomUUID ? crypto.randomUUID() : Math.random().toString(36).slice(2);
    await _vaultStore(vaultId, { data });

    const keys = getKeys();
    keys.push({ name, vaultId, created: new Date().toISOString() });
    localStorage.setItem('sshKeys', JSON.stringify(keys));
    loadKeys();
    document.getElementById('keyName').value = '';
    document.getElementById('keyData').value = '';
    toast(`Key "${name}" saved.`);
  });
});

async function useKey(idx) {
  const key = getKeys()[idx];
  if (!key) return;
  if (!vaultKey) await _tryUnlockVault('required');
  const creds = key.vaultId ? await _vaultLoad(key.vaultId) : null;
  if (!creds) { toast('Vault locked — enter key manually.'); return; }
  document.getElementById('authType').value = 'key';
  document.getElementById('authType').dispatchEvent(new Event('change'));
  document.getElementById('privateKey').value = creds.data;
  toast(`Key "${key.name}" loaded into form.`);
}

function deleteKey(idx) {
  const keys = getKeys();
  const key = keys[idx];
  if (key && key.vaultId) _vaultDelete(key.vaultId);
  keys.splice(idx, 1);
  localStorage.setItem('sshKeys', JSON.stringify(keys));
  loadKeys();
}

// ─── Settings ─────────────────────────────────────────────────────────────────

function initSettingsPanel() {
  const wsInput = document.getElementById('wsUrl');
  wsInput.value = localStorage.getItem('wsUrl') || getDefaultWsUrl();

  // Show ws:// warning on load if the stored URL is insecure
  const wsWarn = document.getElementById('wsWarnInsecure');
  if (wsWarn && wsInput.value.startsWith('ws://')) {
    wsWarn.classList.remove('hidden');
  }

  // ── Danger Zone toggles ──────────────────────────────────────────────────
  // Each toggle persists to localStorage on change. New danger settings can
  // be added here by following the same pattern.
  const dangerAllowWsEl = document.getElementById('dangerAllowWs');
  dangerAllowWsEl.checked = localStorage.getItem('dangerAllowWs') === 'true';
  dangerAllowWsEl.addEventListener('change', () => {
    localStorage.setItem('dangerAllowWs', dangerAllowWsEl.checked ? 'true' : 'false');
  });

  document.getElementById('saveSettingsBtn').addEventListener('click', () => {
    const url = wsInput.value.trim();
    if (url.startsWith('ws://')) {
      if (dangerAllowWsEl.checked) {
        localStorage.setItem('wsUrl', url);
        toast('Saved — warning: ws:// may be blocked by browsers on HTTPS');
      } else {
        toast('ws:// is not allowed — use wss:// (or enable in Danger Zone)');
      }
      return;
    }
    if (!url.startsWith('wss://')) {
      toast('URL must start with wss://');
      return;
    }
    localStorage.setItem('wsUrl', url);
    if (url.startsWith('ws://')) {
      if (wsWarn) wsWarn.classList.remove('hidden');
      toast('Settings saved — warning: ws:// is unencrypted.');
    } else {
      if (wsWarn) wsWarn.classList.add('hidden');
      toast('Settings saved.');
    }
  });

  // Danger zone: allow connections to private/loopback addresses
  const allowPrivateEl = document.getElementById('allowPrivateHosts');
  if (allowPrivateEl) {
    allowPrivateEl.checked = localStorage.getItem('allowPrivateHosts') === 'true';
    allowPrivateEl.addEventListener('change', () => {
      localStorage.setItem('allowPrivateHosts', allowPrivateEl.checked);
      toast(allowPrivateEl.checked
        ? '⚠ Private address connections enabled.'
        : 'SSRF protection re-enabled.');
    });
  }

  document.getElementById('fontSize').addEventListener('input', (e) => {
    applyFontSize(parseInt(e.target.value));
  });

  const themeSelect = document.getElementById('termThemeSelect');
  themeSelect.value = localStorage.getItem('termTheme') || 'dark';
  themeSelect.addEventListener('change', () => {
    applyTheme(themeSelect.value, { persist: true });
  });

  const fontSelect = document.getElementById('termFontSelect');
  fontSelect.value = localStorage.getItem('termFont') || 'jetbrains';
  fontSelect.addEventListener('change', () => {
    localStorage.setItem('termFont', fontSelect.value);
  });

  document.getElementById('clearDataBtn').addEventListener('click', () => {
    if (!confirm('Clear all stored keys, profiles, and settings?')) return;
    localStorage.clear();
    loadProfiles();
    loadKeys();
    toast('All data cleared.');
  });

  document.getElementById('clearCacheBtn').addEventListener('click', () => {
    if (!confirm('Unregister service workers, clear all caches, and reload?')) return;
    clearCacheAndReload();
  });
}

// ─── Service Worker ───────────────────────────────────────────────────────────

function registerServiceWorker() {
  if (!('serviceWorker' in navigator)) return;
  navigator.serviceWorker.register('sw.js').then((reg) => {
    // Check for updates every 60s so stale SWs get replaced promptly
    setInterval(() => reg.update(), 60_000);
  }).catch((err) => {
    console.warn('Service worker registration failed:', err);
  });
}

// Nuke all service workers + caches + storage, then hard-reload.
// Callable from Settings and from the /clear server endpoint.
async function clearCacheAndReload() {
  try {
    const regs = await navigator.serviceWorker.getRegistrations();
    await Promise.all(regs.map((r) => r.unregister()));
  } catch (_) {}
  try {
    const keys = await caches.keys();
    await Promise.all(keys.map((k) => caches.delete(k)));
  } catch (_) {}
  try { localStorage.clear(); } catch (_) {}
  try { sessionStorage.clear(); } catch (_) {}
  location.reload();
}

// ─── Utilities ────────────────────────────────────────────────────────────────

function escHtml(str) {
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

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
