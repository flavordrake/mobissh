/**
 * modules/ime.ts — IME input layer
 *
 * Handles all keyboard/IME input routing from hidden textarea (#imeInput)
 * and direct-mode text input (#directInput) to the SSH stream.
 *
 * State machine for IME input (#106):
 *   idle → composing → previewing → editing
 *
 *   idle:       textarea hidden, no text, input sent immediately to SSH
 *   composing:  IME composition in progress (isComposing=true), text accumulating
 *   previewing: composition ended, text visible with action buttons, not yet sent
 *   editing:    user tapped into textarea to manually edit before committing
 *
 * Also manages: touch/swipe gesture handlers (#32/#37/#16) and
 * pinch-to-zoom (#17). Selection is handled by selection.ts (#55).
 */

import type { IMEDeps } from './types.js';
import { KEY_MAP } from './constants.js';
import { appState } from './state.js';
import { sendSSHInput } from './connection.js';
import { focusIME, setCtrlActive } from './ui.js';
import { isSelectionActive } from './selection.js';

let _handleResize = (): void => {};
let _applyFontSize = (_size: number): void => {};

// ── IME state machine (#106) ────────────────────────────────────────────────
type IMEState = 'idle' | 'composing' | 'previewing' | 'editing';
let _imeState: IMEState = 'idle';

/** Whether "preview mode" is enabled — accumulate compositions for review. */
let _previewMode = localStorage.getItem('imePreviewMode') === 'true';

export function isPreviewMode(): boolean { return _previewMode; }
/** Callback set by initIMEInput to clear preview state (commits text). */
let _clearPreviewCallback: (() => void) | null = null;

export function togglePreviewMode(): void {
  _previewMode = !_previewMode;
  localStorage.setItem('imePreviewMode', _previewMode ? 'true' : 'false');
  const btn = document.getElementById('previewModeBtn');
  if (btn) btn.classList.toggle('preview-active', _previewMode);
  // Toggle textarea visibility — nothing else. No commit, no discard, no state change.
  // Only show if we're actually in a holding state (previewing/editing) with content.
  const hasContent = _imeState === 'previewing' || _imeState === 'editing';
  const ime = document.getElementById('imeInput') as HTMLTextAreaElement | null;
  if (ime) ime.classList.toggle('ime-visible', _previewMode && hasContent);
  const actions = document.getElementById('imeActions');
  if (actions && !_previewMode) actions.classList.add('hidden');
  if (actions && _previewMode && hasContent) actions.classList.remove('hidden');
  console.log('[ime] preview mode:', _previewMode ? 'ON' : 'OFF');
}

/** Clear any active preview — called when compose mode is toggled off. */
export function clearIMEPreview(): void {
  if (_clearPreviewCallback) _clearPreviewCallback();
}

/** Query the current IME state (for tests and debugging). */
export function getIMEState(): IMEState { return _imeState; }

// ── Password-prompt detection — suppress keyboard suggestions (#123) ─────────
// Matches common password/passphrase/PIN prompts at the end of a terminal line.
const _PASSWORD_RE = /(?:password|passphrase|PIN)[^:]*:\s*$/i;
let _pwdListenerSetup = false;

function _checkPasswordPrompt(el: HTMLTextAreaElement): void {
  if (!appState.terminal) return;
  const buf = appState.terminal.buffer.active;
  const lastLine = (buf.getLine(buf.cursorY)?.translateToString(true) ?? '').trimEnd();
  el.setAttribute('autocomplete', _PASSWORD_RE.test(lastLine) ? 'new-password' : 'off');
}

export function initIME({ handleResize, applyFontSize }: IMEDeps): void {
  _handleResize = handleResize;
  _applyFontSize = applyFontSize;
}

export function initIMEInput(): void {
  const ime = document.getElementById('imeInput') as HTMLTextAreaElement;

  // Register cursor-move listener once the terminal is available, and re-check
  // whenever focus lands on the textarea (covers the "prompt just appeared" case).
  function _lazySetupPwdListener(): void {
    if (_pwdListenerSetup || !appState.terminal) return;
    _pwdListenerSetup = true;
    appState.terminal.onCursorMove(() => { _checkPasswordPrompt(ime); });
  }
  ime.addEventListener('focus', () => {
    _lazySetupPwdListener();
    _checkPasswordPrompt(ime);
  });

  // When user taps inside the visible textarea to edit, transition to editing state.
  // This cancels any pending auto-clear timer and makes the textarea sticky.
  ime.addEventListener('touchstart', () => {
    if ((_imeState === 'previewing' || _imeState === 'composing') && ime.value) {
      _transition('editing');
    }
  });

  // ── Preview mode toggle (#106) — wired here to avoid circular import ──
  const previewBtn = document.getElementById('previewModeBtn');
  if (previewBtn) {
    previewBtn.classList.toggle('preview-active', _previewMode);
    previewBtn.addEventListener('click', () => {
      togglePreviewMode();
      focusIME();
    });
  }

  // ── IME action buttons (#106) ────────────────────────────────────────
  const imeActions = document.getElementById('imeActions');
  const clearBtn = document.getElementById('imeClearBtn');
  const commitBtn = document.getElementById('imeCommitBtn');
  const dockToggle = document.getElementById('imeDockToggle');

  let _dockPosition: 'top' | 'bottom' = localStorage.getItem('imeDockPosition') === 'bottom' ? 'bottom' : 'top';
  let _manualDock = false;

  /**
   * Compute effective dock position: if the user explicitly toggled, use that.
   * Otherwise, auto-select based on terminal cursor position — place the preview
   * opposite the cursor so it doesn't obscure the active line.
   * Falls back to _dockPosition (persisted) when terminal is unavailable.
   */
  function _effectiveDock(): 'top' | 'bottom' {
    if (_manualDock) return _dockPosition;
    const term = appState.terminal;
    if (!term) return _dockPosition;
    const cursorY = term.buffer.active.cursorY;
    const rows = term.rows;
    // Cursor in top half → show preview at bottom; cursor in bottom half → show at top
    return cursorY < rows / 2 ? 'bottom' : 'top';
  }

  /** Position the textarea + action bar using visualViewport to avoid the keyboard. */
  function _positionIME(): void {
    const vv = window.visualViewport;
    const viewH = vv ? vv.height : window.innerHeight;
    const viewTop = vv ? vv.offsetTop : 0;
    const actionH = 36; // matches CSS .ime-action-btn height
    const dock = _effectiveDock();

    if (dock === 'top') {
      // Top: just below viewport top
      const top = viewTop + 4;
      ime.style.top = `${String(top)}px`;
      ime.style.bottom = 'auto';
      if (imeActions) {
        imeActions.style.top = `${String(top + ime.offsetHeight)}px`;
        imeActions.style.bottom = 'auto';
      }
    } else {
      // Bottom: above the keyboard
      const bottom = window.innerHeight - (viewTop + viewH) + 8;
      ime.style.bottom = `${String(bottom + actionH)}px`;
      ime.style.top = 'auto';
      if (imeActions) {
        imeActions.style.bottom = `${String(bottom)}px`;
        imeActions.style.top = 'auto';
      }
    }
  }

  // Re-position when viewport changes (keyboard open/close)
  if (window.visualViewport) {
    window.visualViewport.addEventListener('resize', () => {
      if (ime.classList.contains('ime-visible')) _positionIME();
    });
    window.visualViewport.addEventListener('scroll', () => {
      if (ime.classList.contains('ime-visible')) _positionIME();
    });
  }

  /** Show the action button bar and position everything. */
  function _showActions(): void {
    if (imeActions) imeActions.classList.remove('hidden');
    _positionIME();
  }
  /** Hide the action button bar. */
  function _hideActions(): void {
    if (imeActions) imeActions.classList.add('hidden');
  }

  // Prevent buttons from stealing focus (desktop: mousedown preventDefault).
  // On mobile: use touchend handlers directly since touchstart preventDefault
  // swallows the click event on Android.
  if (imeActions) {
    imeActions.addEventListener('mousedown', (e) => { e.preventDefault(); });
  }

  /** Wire an action button for both touch and click. */
  function _onAction(btn: HTMLElement | null, handler: () => void): void {
    if (!btn) return;
    let touchHandled = false;
    btn.addEventListener('touchend', (e) => {
      e.preventDefault(); // prevent click from also firing
      touchHandled = true;
      handler();
    });
    btn.addEventListener('click', () => {
      if (touchHandled) { touchHandled = false; return; }
      handler();
    });
  }

  _onAction(clearBtn, () => {
    // Erase what was already sent to SSH (if anything)
    if (_lastSentValue) sendSSHInput('\x7f'.repeat(_lastSentValue.length));
    _transition('idle');
    focusIME();
  });

  _onAction(commitBtn, () => {
    const text = ime.value;
    if (_imeState === 'editing') {
      // Editing: user rewrote text locally — send full text as-is
      if (text) sendSSHInput(text);
    } else {
      // Previewing/composing: erase any partial sends, send final text
      if (_lastSentValue) sendSSHInput('\x7f'.repeat(_lastSentValue.length));
      if (text) sendSSHInput(text);
    }
    _transition('idle');
    focusIME();
  });

  _onAction(dockToggle, () => {
    // Determine what auto-positioning would choose, then flip from that
    const auto = _effectiveDock();
    _dockPosition = auto === 'top' ? 'bottom' : 'top';
    _manualDock = true;
    localStorage.setItem('imeDockPosition', _dockPosition);
    _positionIME();
    focusIME();
  });

  // ── Textarea diffing state (handles post-composition corrections) ──────
  let _lastSentValue = '';
  let _replacementHandled = false;
  let _clearTimer: ReturnType<typeof setTimeout> | null = null;
  /** Timestamp of most recent transition to idle — used to reject late browser
   *  re-insertion events that fire within a short window after compositionend. */
  let _idleTransitionTime = 0;

  /** Transition the IME state machine. All state changes go through here. */
  function _transition(to: IMEState): void {
    const from = _imeState;
    // Always run idle cleanup even if already idle (commit after auto-clear)
    if (from === to && to !== 'idle') return;
    _imeState = to;

    // Cancel pending clear on any transition
    if (_clearTimer) { clearTimeout(_clearTimer); _clearTimer = null; }
    // No flag to clear — time-based guard handles stale input rejection

    switch (to) {
      case 'idle':
        ime.value = '';
        _lastSentValue = '';
        _idleTransitionTime = Date.now();
        ime.classList.remove('ime-visible', 'ime-editing');
        if (imeActions) imeActions.classList.remove('ime-editing');
        ime.style.height = '';
        _hideActions();
        appState.isComposing = false;
        _manualDock = false;
        break;

      case 'composing':
        appState.isComposing = true;
        ime.classList.add('ime-visible');
        ime.classList.remove('ime-editing');
        if (imeActions) imeActions.classList.remove('ime-editing');
        _showActions();
        _positionIME();
        break;

      case 'previewing':
        appState.isComposing = false;
        ime.classList.add('ime-visible');
        ime.classList.remove('ime-editing');
        if (imeActions) imeActions.classList.remove('ime-editing');
        _showActions();
        _positionIME();
        break;

      case 'editing':
        appState.isComposing = false;
        ime.classList.add('ime-visible', 'ime-editing');
        if (imeActions) imeActions.classList.add('ime-editing');
        _showActions();
        _positionIME();
        break;
    }
  }

  /** Whether input should be held (not sent to SSH). */
  function _isHolding(): boolean {
    return _imeState === 'previewing' || _imeState === 'editing';
  }

  /** Whether the IME should stick indefinitely (no auto-clear). */
  function _isSticky(): boolean {
    return _imeState === 'editing';
  }

  /** Show the overlay and auto-size the textarea (only if preview mode is on). */
  function _showIMEOverlay(): void {
    if (!_previewMode) return;
    ime.classList.add('ime-visible');
    if (_imeState !== 'idle') _showActions();
    _positionIME();
    // Auto-grow: reset height then set to scrollHeight, capped by CSS max-height
    if (document.body.classList.contains('debug-ime')) {
      ime.style.height = 'auto';
      ime.style.height = `${String(ime.scrollHeight)}px`;
    }
  }

  /** Schedule a deferred clear — gives the IME time to fire correction events
   *  after compositionend. Skipped only when editing (user tapped in).
   *  Previewing gets a longer timeout (5s) to allow review before auto-commit. */
  function _scheduleClear(): void {
    if (_clearTimer) clearTimeout(_clearTimer);
    if (_isSticky()) return;
    const delay = _imeState === 'previewing' ? 5000 : 1500;
    _clearTimer = setTimeout(() => {
      // Don't auto-commit if user entered editing or a new composition started
      if (_imeState === 'composing' || _imeState === 'editing') return;

      if (_imeState === 'previewing') {
        const text = ime.value;
        if (text) {
          // Send completed words (up to last space), keep trailing partial
          const lastSpace = text.lastIndexOf(' ');
          if (lastSpace >= 0) {
            const committed = text.slice(0, lastSpace + 1);
            const remainder = text.slice(lastSpace + 1);
            sendSSHInput(committed);
            ime.value = remainder;
            if (remainder) {
              // Still have a partial word — stay in previewing, reset timer
              _lastSentValue = '';
              _scheduleClear();
              return;
            }
          } else {
            // Single word, no spaces — send it all
            sendSSHInput(text);
          }
        }
      }
      _transition('idle');
    }, delay);
  }

  // Register callback so toggleComposeMode() can commit+clear active preview
  _clearPreviewCallback = () => {
    if (appState.isComposing) appState.isComposing = false;
    const text = ime.value;
    if (text) sendSSHInput(text);
    _transition('idle');
  };


  /** Send text to SSH with Ctrl modifier handling. */
  function _sendIMEText(text: string): void {
    if (text === '\n') {
      sendSSHInput('\r');
      ime.setAttribute('autocomplete', 'off');
      _transition('idle');
      return;
    }
    if (appState.ctrlActive) {
      const code = text[0]!.toLowerCase().charCodeAt(0) - 96;
      sendSSHInput(code >= 1 && code <= 26 ? String.fromCharCode(code) : text);
      setCtrlActive(false);
    } else {
      sendSSHInput(text);
    }
  }

  /** Diff old vs new value: send backspaces to erase changed region + replacement text. */
  function _sendDiff(oldVal: string, newVal: string): void {
    if (oldVal === newVal) return;
    // Find longest common prefix
    let prefix = 0;
    while (prefix < oldVal.length && prefix < newVal.length && oldVal[prefix] === newVal[prefix]) prefix++;
    // Find longest common suffix (not overlapping prefix)
    let suffix = 0;
    while (suffix < oldVal.length - prefix && suffix < newVal.length - prefix &&
           oldVal[oldVal.length - 1 - suffix] === newVal[newVal.length - 1 - suffix]) suffix++;
    const deletions = oldVal.length - prefix - suffix;
    const insertion = newVal.slice(prefix, newVal.length - suffix);
    if (deletions > 0) sendSSHInput('\x7f'.repeat(deletions));
    if (insertion) sendSSHInput(insertion);
  }

  // ── beforeinput: intercept IME corrections before they hit the textarea ──
  ime.addEventListener('beforeinput', (e: InputEvent) => {
    _replacementHandled = false;
    // When holding (previewing/editing), let the textarea update freely
    if (_isHolding()) return;

    // insertReplacementText: Gboard/iOS correction after swipe-type (#231)
    if (e.inputType === 'insertReplacementText' && e.data) {
      const ranges = e.getTargetRanges();
      if (ranges.length > 0) {
        const r = ranges[0]!;
        // For a textarea, startOffset/endOffset map to selectionStart/selectionEnd
        const deleteCount = r.endOffset - r.startOffset;
        if (deleteCount > 0) sendSSHInput('\x7f'.repeat(deleteCount));
        sendSSHInput(e.data);
        e.preventDefault();
        // Update tracking: replace the range in lastSentValue
        _lastSentValue = _lastSentValue.slice(0, r.startOffset) + e.data +
                         _lastSentValue.slice(r.endOffset);
        _replacementHandled = true;
        return;
      }
      // If ranges empty (some Chrome versions), fall through to textarea diff in input handler
    }

    // deleteWordBackward: Gboard-specific correction sequence (#231)
    if (e.inputType === 'deleteWordBackward' && !appState.isComposing) {
      const start = ime.selectionStart;
      const before = ime.value.slice(0, start);
      // Find word boundary
      const match = before.match(/\S+\s*$/);
      const deleteCount = match ? match[0].length : before.length;
      if (deleteCount > 0) {
        sendSSHInput('\x7f'.repeat(deleteCount));
        _lastSentValue = _lastSentValue.slice(0, start - deleteCount) + _lastSentValue.slice(start);
        _replacementHandled = true;
      }
      // Don't preventDefault — let the browser update the textarea so
      // the subsequent insertText has correct content to diff against
    }
  });

  // ── input event ─────────────────────────────────────────────────────────
  ime.addEventListener('input', () => {
    // Browser can re-insert composed text after compositionend + _transition('idle').
    // Reject input events within 150ms of idle transition — covers all late re-insertion
    // without permanently blocking input (which caused first/every-other word loss).
    if (Date.now() - _idleTransitionTime < 150) {
      if (ime.value) { ime.value = ''; }
      return;
    }
    // When holding, just keep the overlay — don't send to SSH
    if (_isHolding()) {
      _showIMEOverlay();
      return;
    }
    if (appState.isComposing) {
      _showIMEOverlay();
      return;
    }

    // If beforeinput already handled this (insertReplacementText with ranges), skip
    if (_replacementHandled) {
      _replacementHandled = false;
      return;
    }

    const newVal = ime.value;
    if (!newVal) { _transition('idle'); return; }
    _showIMEOverlay();

    // Hold for preview: don't send, transition to previewing with auto-clear.
    // GBoard swipe may fire input events without composition events, so this
    // path must mirror the compositionend preview-hold logic.
    if (appState.imeMode && _previewMode) {
      _transition('previewing');
      _lastSentValue = '';
      _scheduleClear();
      return;
    }

    // If we have a previous value to diff against, use textarea diffing
    // to detect corrections the beforeinput handler couldn't catch
    if (_lastSentValue) {
      _sendDiff(_lastSentValue, newVal);
      _lastSentValue = newVal;
    } else {
      // Fresh input (no prior value to diff against)
      _sendIMEText(newVal);
      _lastSentValue = newVal;
    }

    // No preview: clear after sending
    _transition('idle');
  });

  // ── IME composition (multi-step input methods, e.g. CJK, Gboard swipe) ─
  ime.addEventListener('compositionstart', () => {
    // New composition: clear any stale text that browser might have re-inserted
    if (_imeState === 'idle') ime.value = '';
    // Preserve editing state — user tapped in to edit, new composition should
    // stay sticky (no auto-clear). Only transition to composing from non-editing.
    if (_imeState !== 'editing') _transition('composing');
    else appState.isComposing = true;
    _showIMEOverlay();
  });

  ime.addEventListener('compositionupdate', () => {
    _showIMEOverlay();
  });

  ime.addEventListener('compositionend', (e: CompositionEvent) => {
    // If already holding (editing/previewing), stay — accumulate text
    if (_isHolding()) {
      appState.isComposing = false;
      _showIMEOverlay();
      return;
    }

    const text = ime.value || e.data;
    if (!text) { _transition('idle'); return; }

    // Compose + preview: hold text for review (nothing sent until commit)
    if (appState.imeMode && _previewMode) {
      _transition('previewing');
      _lastSentValue = '';
      _scheduleClear();
      return;
    }

    // No preview: send immediately, but keep textarea alive briefly
    // so voice dictation sessions can continue across composition cycles.
    appState.isComposing = false;
    _sendIMEText(text);
    _lastSentValue = '';
    ime.value = '';
    // Move to previewing (allows tap-to-edit and deferred idle timer)
    _imeState = 'previewing';
    // Deferred idle: if no new compositionstart within 1.5s, hide textarea
    if (_clearTimer) clearTimeout(_clearTimer);
    _clearTimer = setTimeout(() => {
      if (_imeState === 'composing') return; // new composition started
      _transition('idle');
    }, 1500);
  });

  ime.addEventListener('compositioncancel' as keyof HTMLElementEventMap, () => {
    _transition('idle');
  });

  // ── keydown: special keys not captured by 'input' ─────────────────────
  ime.addEventListener('keydown', (e) => {
    // Enter: commit held text and send \r
    if (e.key === 'Enter') {
      ime.setAttribute('autocomplete', 'off');
      const text = ime.value;
      if (_isHolding() && text) {
        e.preventDefault();
        sendSSHInput(text);
        sendSSHInput('\r');
        _transition('idle');
        focusIME();
        return;
      }
      _transition('idle');
    }

    if (e.ctrlKey && !e.altKey && e.key.length === 1) {
      const code = e.key.toLowerCase().charCodeAt(0) - 96;
      if (code >= 1 && code <= 26) {
        sendSSHInput(String.fromCharCode(code));
        _transition('idle');
        e.preventDefault();
        return;
      }
    }

    const mapped = KEY_MAP[e.key];
    if (mapped) {
      // In compose mode, let navigation keys work natively in the textarea
      const isNav = e.key.startsWith('Arrow') || e.key === 'Home' || e.key === 'End';
      if (appState.imeMode && isNav) {
        // Don't send to SSH, don't clear — let textarea handle cursor movement
        return;
      }
      sendSSHInput(mapped);
      _transition('idle');
      e.preventDefault();
      return;
    }

    if (!appState.imeMode && e.key.length === 1 && !e.ctrlKey && !e.altKey && !e.metaKey) {
      if (appState.ctrlActive) {
        const code = e.key.toLowerCase().charCodeAt(0) - 96;
        sendSSHInput(code >= 1 && code <= 26 ? String.fromCharCode(code) : e.key);
        setCtrlActive(false);
      } else {
        sendSSHInput(e.key);
      }
      e.preventDefault();
      _transition('idle');
    }
  });

  // termEl used by gesture handlers and pinch-to-zoom
  const termEl = document.getElementById('terminal')!;

  // ── Tap + swipe gestures on terminal (#32/#37/#16) ────────────────────

  termEl.addEventListener('click', () => { if (!isSelectionActive()) focusIME(); });

  let _touchStartY: number | null = null;
  let _touchStartX: number | null = null;
  let _lastTouchY: number | null = null;
  let _lastTouchX: number | null = null;
  let _isTouchScroll = false;
  let _scrolledLines = 0;
  let _pendingLines = 0;
  let _pendingSGR: { btn: number; col: number; row: number; count: number } | null = null;
  let _scrollRafId: number | null = null;

  function _flushScroll(): void {
    _scrollRafId = null;
    if (_pendingLines !== 0 && appState.terminal) {
      console.log('[scroll] flush scrollLines=', _pendingLines);
      appState.terminal.scrollLines(_pendingLines);
      _pendingLines = 0;
    }
    if (_pendingSGR && _pendingSGR.count > 0) {
      const { btn, col, row, count } = _pendingSGR;
      console.log('[scroll] flush SGR btn=', btn, 'count=', count, 'col=', col, 'row=', row);
      for (let i = 0; i < count; i++) sendSSHInput(`\x1b[<${String(btn)};${String(col)};${String(row)}M`);
      _pendingSGR = null;
    }
  }

  function _scheduleScrollFlush(): void {
    if (!_scrollRafId) _scrollRafId = requestAnimationFrame(_flushScroll);
  }

  // nosemgrep: duplicate-event-listener -- scroll (1-finger) and pinch (2-finger) are separate gestures
  termEl.addEventListener('touchstart', (e) => {
    if (isSelectionActive()) return;
    console.log('[scroll] touchstart y=', e.touches[0]!.clientY, 'touches=', e.touches.length);
    _touchStartY = _lastTouchY = e.touches[0]!.clientY;
    _touchStartX = _lastTouchX = e.touches[0]!.clientX;
    _isTouchScroll = false;
    _scrolledLines = 0;
    _pendingLines = 0;
    _pendingSGR = null;
    if (_scrollRafId) { cancelAnimationFrame(_scrollRafId); _scrollRafId = null; }
  }, { passive: true, capture: true });

  // nosemgrep: duplicate-event-listener
  termEl.addEventListener('touchmove', (e) => {
    if (isSelectionActive()) return;
    if (_touchStartY === null || _touchStartX === null) return;
    const totalDy = _touchStartY - e.touches[0]!.clientY;
    const totalDx = _touchStartX - e.touches[0]!.clientX;

    if (!_isTouchScroll && Math.abs(totalDy) > 12 && Math.abs(totalDy) > Math.abs(totalDx)) {
      _isTouchScroll = true;
      console.log('[scroll] gesture claimed, totalDy=', totalDy);
    }

    // Once we've claimed this gesture as a terminal scroll, prevent the
    // browser's native scroll/bounce so it doesn't fight our handler.
    if (_isTouchScroll) e.preventDefault();

    if (_isTouchScroll && appState.terminal) {
      const cellH = Math.max(20, (appState.terminal.options.fontSize ?? 14) * 1.5);
      const targetLines = Math.round(totalDy / cellH);
      const delta = targetLines - _scrolledLines;
      if (delta !== 0) {
        _scrolledLines = targetLines;
        // eslint-disable-next-line @typescript-eslint/no-unsafe-member-access -- xterm modes is untyped
        const termUnk = appState.terminal as unknown as Record<string, unknown>;
        const mouseMode = termUnk.modes &&
          (termUnk.modes as Record<string, unknown>).mouseTrackingMode;
        console.log('[scroll] delta=', delta, 'mouseMode=', mouseMode);
        if (mouseMode && mouseMode !== 'none') {
          const natural = _naturalVerticalScroll();
          // delta>0 = finger UP, delta<0 = finger DOWN
          // Natural: finger down(-delta) = see older = WheelUp(64)
          // Traditional: finger up(+delta) = see older = WheelUp(64)
          const btn = natural
            ? (delta > 0 ? 65 : 64)
            : (delta > 0 ? 64 : 65);
          const rect = termEl.getBoundingClientRect();
          const col = Math.max(1, Math.min(appState.terminal.cols,
            Math.floor((e.touches[0]!.clientX - rect.left) / (rect.width / appState.terminal.cols)) + 1));
          const row = Math.max(1, Math.min(appState.terminal.rows,
            Math.floor((e.touches[0]!.clientY - rect.top) / (rect.height / appState.terminal.rows)) + 1));
          const count = Math.abs(delta);
          if (_pendingSGR?.btn === btn) {
            _pendingSGR.count += count;
          } else {
            _pendingSGR = { btn, col, row, count };
          }
          console.log('[scroll] SGR queued btn=', btn, 'count=', count);
        } else {
          // Natural: delta maps directly (finger down = -delta = scrollLines(-) = older)
          // Traditional: invert (finger up = +delta → -delta = scrollLines(-) = older)
          _pendingLines += _naturalVerticalScroll() ? delta : -delta;
          console.log('[scroll] scrollLines queued=', _pendingLines);
        }
        _scheduleScrollFlush();
      }
    }

    _lastTouchY = e.touches[0]!.clientY;
    _lastTouchX = e.touches[0]!.clientX;
  }, { passive: false, capture: true });

  // nosemgrep: duplicate-event-listener
  termEl.addEventListener('touchend', () => {
    if (isSelectionActive()) return;
    const wasScroll = _isTouchScroll;
    const finalDx = (_lastTouchX ?? _touchStartX ?? 0) - (_touchStartX ?? 0);
    const finalDy = (_lastTouchY ?? _touchStartY ?? 0) - (_touchStartY ?? 0);

    _touchStartY = _touchStartX = _lastTouchY = _lastTouchX = null;
    _isTouchScroll = false;
    _scrolledLines = 0;
    // Flush any remaining scroll deltas before clearing — if the last touchmove
    // queued lines that rAF hasn't flushed yet, discarding them loses the scroll.
    _flushScroll();
    _pendingLines = 0;
    _pendingSGR = null;
    if (_scrollRafId) { cancelAnimationFrame(_scrollRafId); _scrollRafId = null; }

    if (!wasScroll) {
      if (Math.abs(finalDx) > 40 && Math.abs(finalDx) > Math.abs(finalDy)) {
        const hNatural = _naturalHorizontalScroll();
        const hCmd = hNatural
          ? (finalDx < 0 ? '\x02p' : '\x02n')   // natural: finger left = prev
          : (finalDx < 0 ? '\x02n' : '\x02p');   // traditional: finger left = next
        sendSSHInput(hCmd);
      } else {
        setTimeout(focusIME, 50);
      }
    }
  }, { capture: true });

  // ── Pinch-to-zoom → font size (#17) — behind enablePinchZoom setting ────
  let _pinchStartDist: number | null = null;
  let _pinchStartSize: number | null = null;

  function _pinchEnabled(): boolean {
    return localStorage.getItem('enablePinchZoom') !== 'false';
  }

  function _naturalVerticalScroll(): boolean {
    return localStorage.getItem('naturalVerticalScroll') !== 'false';
  }

  function _naturalHorizontalScroll(): boolean {
    return localStorage.getItem('naturalHorizontalScroll') !== 'false';
  }

  function _pinchDist(touches: TouchList): number {
    const dx = touches[0]!.clientX - touches[1]!.clientX;
    const dy = touches[0]!.clientY - touches[1]!.clientY;
    return Math.sqrt(dx * dx + dy * dy);
  }

  termEl.addEventListener('touchstart', (e) => {
    if (e.touches.length !== 2 || !_pinchEnabled()) return;
    _pinchStartDist = _pinchDist(e.touches);
    _pinchStartSize = appState.terminal
      ? (appState.terminal.options.fontSize ?? 14)
      : (parseInt(localStorage.getItem('fontSize') ?? '14') || 14);
    e.preventDefault();
  }, { passive: false });

  termEl.addEventListener('touchmove', (e) => {
    if (e.touches.length !== 2 || _pinchStartDist === null || _pinchStartSize === null) return;
    e.preventDefault();
    const newSize = Math.round(_pinchStartSize * (_pinchDist(e.touches) / _pinchStartDist));
    _applyFontSize(newSize);
  }, { passive: false });

  termEl.addEventListener('touchend', () => {
    _pinchStartDist = null;
    _pinchStartSize = null;
  });

  termEl.addEventListener('touchcancel', () => {
    _pinchStartDist = null;
    _pinchStartSize = null;
  });

  // ── Direct input (type="password") — char-by-char mode (#44/#48/#155) ──
  // type="password" suppresses Gboard predictions so typed characters don't
  // leak into the keyboard suggestion bar.  Characters are also intercepted
  // via beforeinput so they never reach the field value.
  const directEl = document.getElementById('directInput') as HTMLInputElement;

  /** Send direct-mode text to SSH, handling sticky Ctrl modifier. */
  function _sendDirectText(text: string): void {
    if (text === '\n') { sendSSHInput('\r'); return; }
    if (appState.ctrlActive) {
      const code = text[0]!.toLowerCase().charCodeAt(0) - 96;
      sendSSHInput(code >= 1 && code <= 26 ? String.fromCharCode(code) : text);
      setCtrlActive(false);
    } else {
      sendSSHInput(text);
    }
  }

  // Intercept text BEFORE it modifies the field value — characters never
  // appear in the input, so Chrome autocomplete sees nothing to suggest.
  let _sentByBeforeInput = false;
  directEl.addEventListener('beforeinput', (e) => {
    e.preventDefault();
    _sentByBeforeInput = false;
    if (e.inputType === 'insertText' && e.data) {
      _sendDirectText(e.data);
      _sentByBeforeInput = true;
    } else if (e.inputType === 'insertLineBreak' || e.inputType === 'insertParagraph') {
      sendSSHInput('\r');
      _sentByBeforeInput = true;
    } else if (e.inputType === 'deleteContentBackward') {
      sendSSHInput('\x7f');
      _sentByBeforeInput = true;
    }
  });

  // Fallback: clear any characters that slip past beforeinput (non-cancelable
  // composition events or very old browsers without beforeinput support).
  directEl.addEventListener('input', () => {
    const text = directEl.value;
    directEl.value = '';
    if (_sentByBeforeInput) { _sentByBeforeInput = false; return; }
    if (text) _sendDirectText(text);
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
    const mapped = KEY_MAP[e.key];
    if (mapped) {
      sendSSHInput(mapped);
      e.preventDefault();
      return;
    }
    if (!appState.imeMode && e.key.length === 1 && !e.ctrlKey && !e.altKey && !e.metaKey) {
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
