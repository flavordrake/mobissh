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
  const { protocol, host } = window.location;
  const wsProtocol = protocol === 'https:' ? 'wss:' : 'ws:';
  return `${wsProtocol}//${host}`;
}

const RECONNECT = {
  INITIAL_DELAY_MS: 2000,
  MAX_DELAY_MS: 30000,
  BACKOFF_FACTOR: 1.5,
};

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
let wsConnected = false;   // WebSocket open
let sshConnected = false;  // SSH session established
let currentProfile = null;
let reconnectTimer = null;
let reconnectDelay = RECONNECT.INITIAL_DELAY_MS;
let keepAliveTimer = null; // application-layer WS keepalive (#29)
let isComposing = false;   // IME composition in progress
let ctrlActive = false;    // sticky Ctrl modifier
let vaultKey = null;       // AES-GCM CryptoKey, null when locked
let keyBarVisible = true;  // key bar show/hide state (#1)
let imeMode = true;        // true = IME/swipe, false = direct char entry (#2)
let tabBarVisible = true;  // visible on cold start (#36); auto-hides after first connect
let hasConnected = false;  // true after first successful SSH session (#36)

// ─── Startup ─────────────────────────────────────────────────────────────────

document.addEventListener('DOMContentLoaded', () => {
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

  // Cold start UX (#36): if profiles exist, land on Connect so user can tap to connect
  if (getProfiles().length > 0) {
    document.querySelector('[data-panel="connect"]').click();
  }

  // Apply saved font size (applyFontSize syncs all UI)
  applyFontSize(parseInt(localStorage.getItem('fontSize')) || 14);
});

// ─── Terminal ─────────────────────────────────────────────────────────────────

function initTerminal() {
  const fontSize = parseInt(localStorage.getItem('fontSize')) || 14;

  terminal = new Terminal({
    fontFamily: '"JetBrains Mono", "Fira Code", "Cascadia Code", monospace',
    fontSize,
    theme: {
      background: '#000000',
      foreground: '#e0e0e0',
      cursor: '#00ff88',
      selectionBackground: '#00ff8844',
    },
    cursorBlink: true,
    scrollback: 5000,
    convertEol: false,
  });

  fitAddon = new FitAddon.FitAddon();
  terminal.loadAddon(fitAddon);
  terminal.open(document.getElementById('terminal'));
  fitAddon.fit();

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

const FONT_SIZE = { MIN: 8, MAX: 24 };

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
  }
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
  ime.addEventListener('input', (e) => {
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
    const text = e.data || ime.value;
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

  // ── Focus management + touch scroll (#32/#37) ─────────────────────────
  // Gesture mapping:
  //   tap          → focusIME (shows soft keyboard)
  //   vertical swipe → WheelEvent on .xterm-viewport
  //                    xterm.js handles this for BOTH scrollback (normal mode)
  //                    and mouse protocol reporting (tmux mouse on / DECSET 1000/1002/1006)
  //   horizontal swipe → ignored here (reserved for future tmux window gestures, #16)
  //
  // touch-action:none on #terminal prevents browser panning so we don't need
  // e.preventDefault() — passive:true listeners are safe.
  const termEl = document.getElementById('terminal');
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
  }, { passive: true, capture: true });

  termEl.addEventListener('touchmove', (e) => {
    if (_touchStartY === null) return;
    const totalDy = _touchStartY - e.touches[0].clientY;
    const totalDx = _touchStartX - e.touches[0].clientX;

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

    if (!wasScroll) {
      // Horizontal swipe: more than 40px X, dominant over Y → tmux window switch (#16).
      if (Math.abs(finalDx) > 40 && Math.abs(finalDx) > Math.abs(finalDy)) {
        // Swipe left (finalDx < 0) → next window; swipe right → previous window.
        sendSSHInput(finalDx < 0 ? '\x02n' : '\x02p');
      } else {
        setTimeout(focusIME, 50);
      }
    }
  }, { capture: true });

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

  // Refocus after key-bar buttons (except Ctrl which handles its own focus)
  document.querySelectorAll('.key-btn:not(.modifier)').forEach((btn) => {
    btn.addEventListener('click', () => setTimeout(focusIME, 50));
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
    wsConnected = true;
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
        break;

      case 'error':
        terminal.writeln(ANSI.red(`Error: ${msg.message}`));
        break;

      case 'disconnected':
        sshConnected = false;
        setStatus('disconnected', 'Disconnected');
        terminal.writeln(ANSI.yellow(`Disconnected: ${msg.reason || 'unknown reason'}`));
        scheduleReconnect();
        break;
    }
  };

  ws.onclose = (event) => {
    wsConnected = false;
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
  cancelReconnect();
  stopKeepAlive();
  releaseWakeLock();
  currentProfile = null;
  sshConnected = false;
  wsConnected = false;

  if (ws) {
    ws.onclose = null;
    try { ws.send(JSON.stringify({ type: 'disconnect' })); } catch (_) {}
    ws.close();
    ws = null;
  }

  setStatus('disconnected', 'Disconnected');
  terminal.writeln(ANSI.yellow('Disconnected.'));
}

// ─── Status indicator ─────────────────────────────────────────────────────────

function setStatus(state, text) {
  const el = document.getElementById('statusIndicator');
  el.className = `status ${state}`;
  document.getElementById('statusText').textContent = text;

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

function initTerminalActions() {
  document.getElementById('keyCtrl').addEventListener('click', () => {
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
    document.getElementById(id).addEventListener('click', () => {
      sendSSHInput(seq);
      focusIME();
    });
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
// Credentials are AES-GCM encrypted at rest. The vault key is a random 32-byte
// value stored in the browser's credential store (navigator.credentials),
// which on Android Chrome is backed by device biometric / screen lock.

const VAULT_CRED_ID = 'ssh-pwa-vault';

function _b64(bytes) {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}
function _bytes(b64) {
  return Uint8Array.from(atob(b64), c => c.charCodeAt(0));
}

async function initVault() {
  if (!('credentials' in navigator)) return;
  const vault = JSON.parse(localStorage.getItem('sshVault') || '{}');
  if (!Object.keys(vault).length) return; // nothing stored yet
  await _tryUnlockVault('silent');
}

async function _tryUnlockVault(mediation) {
  if (!('credentials' in navigator)) return false;
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

async function _ensureVaultKey() {
  if (vaultKey) return true;
  if (!('credentials' in navigator) || !window.PasswordCredential) return false;
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
    vaultId,
  };

  // Store credentials in vault
  const hasVault = await _ensureVaultKey();
  if (hasVault) {
    const creds = {};
    if (profile.password)   creds.password   = profile.password;
    if (profile.privateKey) creds.privateKey = profile.privateKey;
    if (profile.passphrase) creds.passphrase = profile.passphrase;
    if (Object.keys(creds).length) {
      await _vaultStore(vaultId, creds);
      saved.hasVaultCreds = true;
    }
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
    <div class="profile-item" onclick="loadProfileIntoForm(${i})" ontouchstart="this.classList.add('tapped')" ontouchend="this.classList.remove('tapped')">
      <span class="profile-name">${escHtml(p.name)}${p.hasVaultCreds ? ' <span class="vault-badge">saved</span>' : ''}</span>
      <span class="profile-host">${escHtml(p.username)}@${escHtml(p.host)}:${p.port || 22}</span>
      <div class="item-actions">
        <button class="item-btn" onclick="loadProfileIntoForm(${i})">✎ Edit</button>
        <button class="item-btn danger" onclick="event.stopPropagation(); deleteProfile(${i})">Delete</button>
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
        <button class="item-btn" onclick="useKey(${i})">Use in form</button>
        <button class="item-btn danger" onclick="deleteKey(${i})">Delete</button>
      </div>
    </div>
  `).join('');
}

document.addEventListener('DOMContentLoaded', () => {
  document.getElementById('importKeyBtn').addEventListener('click', () => {
    const name = document.getElementById('keyName').value.trim();
    const data = document.getElementById('keyData').value.trim();
    if (!name || !data) { toast('Name and key data are required.'); return; }
    if (!data.includes('PRIVATE KEY')) { toast('Does not look like a PEM private key.'); return; }

    const keys = getKeys();
    keys.push({ name, data, created: new Date().toISOString() });
    localStorage.setItem('sshKeys', JSON.stringify(keys));
    loadKeys();
    document.getElementById('keyName').value = '';
    document.getElementById('keyData').value = '';
    toast(`Key "${name}" saved.`);
  });
});

function useKey(idx) {
  const key = getKeys()[idx];
  if (!key) return;
  document.getElementById('authType').value = 'key';
  document.getElementById('authType').dispatchEvent(new Event('change'));
  document.getElementById('privateKey').value = key.data;
  toast(`Key "${key.name}" loaded into form.`);
}

function deleteKey(idx) {
  const keys = getKeys();
  keys.splice(idx, 1);
  localStorage.setItem('sshKeys', JSON.stringify(keys));
  loadKeys();
}

// ─── Settings ─────────────────────────────────────────────────────────────────

function initSettingsPanel() {
  const wsInput = document.getElementById('wsUrl');
  wsInput.value = localStorage.getItem('wsUrl') || getDefaultWsUrl();

  document.getElementById('saveSettingsBtn').addEventListener('click', () => {
    const url = wsInput.value.trim();
    if (!url.startsWith('ws://') && !url.startsWith('wss://')) {
      toast('URL must start with ws:// or wss://');
      return;
    }
    localStorage.setItem('wsUrl', url);
    toast('Settings saved.');
  });

  document.getElementById('fontSize').addEventListener('input', (e) => {
    applyFontSize(parseInt(e.target.value));
  });

  document.getElementById('clearDataBtn').addEventListener('click', () => {
    if (!confirm('Clear all stored keys, profiles, and settings?')) return;
    localStorage.clear();
    loadProfiles();
    loadKeys();
    toast('All data cleared.');
  });
}

// ─── Service Worker ───────────────────────────────────────────────────────────

function registerServiceWorker() {
  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.register('sw.js').catch((err) => {
      console.warn('Service worker registration failed:', err);
    });
  }
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
