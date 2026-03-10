/**
 * modules/ime.ts — IME input layer
 *
 * Handles all keyboard/IME input routing from hidden textarea (#imeInput)
 * and direct-mode text input (#directInput) to the SSH stream.
 *
 * Also manages: touch/swipe gesture handlers (#32/#37/#16) and
 * pinch-to-zoom (#17). Selection is handled by selection.ts (#55).
 */

import type { IMEDeps } from './types.js';
import { KEY_MAP } from './constants.js';
import { appState } from './state.js';
import { sendSSHInput } from './connection.js';
import { focusIME, setCtrlActive, toggleComposeMode } from './ui.js';
import { isSelectionActive } from './selection.js';

let _handleResize = (): void => {};
let _applyFontSize = (_size: number): void => {};

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

  // ── IME composition preview helper (#44) ──────────────────────────────
  function _imePreviewShow(text: string | null): void {
    const el = document.getElementById('imePreview');
    if (!el) return;
    if (text) {
      const textEl = document.getElementById('imePreviewText');
      if (textEl) textEl.textContent = text;
      el.classList.remove('hidden');
    } else {
      el.classList.add('hidden');
    }
  }

  // ── Preview action buttons: Clear and Send (#74) ───────────────────────
  const clearBtn = document.getElementById('imeClearBtn');
  const commitBtn = document.getElementById('imeCommitBtn');

  if (clearBtn) {
    clearBtn.addEventListener('click', () => {
      _clearIME();
      _imePreviewShow(null);
    });
  }

  if (commitBtn) {
    commitBtn.addEventListener('click', () => {
      sendSSHInput('\r');
      _clearIME();
      _imePreviewShow(null);
    });
  }

  // ── Dock toggle: swap preview between top and bottom (#106) ─────────────
  const dockToggle = document.getElementById('imeDockToggle');
  const previewEl = document.getElementById('imePreview');
  if (dockToggle && previewEl) {
    dockToggle.addEventListener('click', () => {
      const isBottom = previewEl.classList.contains('ime-preview-bottom');
      previewEl.classList.toggle('ime-preview-bottom', !isBottom);
      previewEl.classList.toggle('ime-preview-top', isBottom);
      localStorage.setItem('imeDockPosition', isBottom ? 'top' : 'bottom');
    });
    // Restore saved position
    const saved = localStorage.getItem('imeDockPosition');
    if (saved === 'top') {
      previewEl.classList.remove('ime-preview-bottom');
      previewEl.classList.add('ime-preview-top');
    }
  }

  // ── Textarea diffing state (handles post-composition corrections) ──────
  // Track what we've sent to SSH so we can diff against the textarea value
  // when the IME replaces text after compositionend (e.g., swipe correction).
  // See docs/ime-compose-research.md for the full rationale.
  let _lastSentValue = '';
  let _replacementHandled = false;
  let _clearTimer: ReturnType<typeof setTimeout> | null = null;

  /** Reset the textarea and diff tracking state. */
  function _clearIME(): void {
    if (_clearTimer) { clearTimeout(_clearTimer); _clearTimer = null; }
    ime.value = '';
    _lastSentValue = '';
    ime.classList.remove('ime-visible');
    ime.style.height = '';
  }

  /** Show the debug overlay and auto-size to content. */
  function _showIMEOverlay(): void {
    ime.classList.add('ime-visible');
    // Auto-grow: reset height then set to scrollHeight, capped by CSS max-height
    if (document.body.classList.contains('debug-ime')) {
      ime.style.height = 'auto';
      ime.style.height = `${String(ime.scrollHeight)}px`;
    }
  }

  /** Schedule a deferred clear — gives the IME time to fire correction events
   *  after compositionend, then clears so the textarea doesn't accumulate. */
  function _scheduleClear(): void {
    if (_clearTimer) clearTimeout(_clearTimer);
    _clearTimer = setTimeout(_clearIME, 1500);
  }

  /** Send text to SSH with Ctrl modifier handling. */
  function _sendIMEText(text: string): void {
    if (text === '\n') {
      sendSSHInput('\r');
      ime.setAttribute('autocomplete', 'off');
      _clearIME();
      if (appState.imeMode) toggleComposeMode();
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
    if (appState.isComposing) {
      _imePreviewShow(ime.value || null);
      return;
    }

    // If beforeinput already handled this (insertReplacementText with ranges), skip
    if (_replacementHandled) {
      _replacementHandled = false;
      return;
    }

    const newVal = ime.value;
    if (!newVal) { _clearIME(); return; }
    _showIMEOverlay();

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

    // Clear on word acceptance (space = user moved on, no more corrections expected)
    if (newVal.endsWith(' ')) {
      _clearIME();
      return;
    }

    // In non-compose mode, clear the textarea after sending
    if (!appState.imeMode) {
      _clearIME();
    }
  });

  // ── IME composition (multi-step input methods, e.g. CJK, Gboard swipe) ─
  ime.addEventListener('compositionstart', () => {
    appState.isComposing = true;
    // Cancel any pending clear — new composition needs the textarea
    if (_clearTimer) { clearTimeout(_clearTimer); _clearTimer = null; }
    _showIMEOverlay();
  });

  ime.addEventListener('compositionupdate', (e: CompositionEvent) => {
    if (e.data) _imePreviewShow(e.data);
    _showIMEOverlay();
  });

  ime.addEventListener('compositionend', (e: CompositionEvent) => {
    appState.isComposing = false;
    _imePreviewShow(null);
    const text = ime.value || e.data;
    if (!text) { _clearIME(); return; }
    _sendIMEText(text);
    _lastSentValue = text;

    // In non-compose mode, clear immediately.
    // In compose mode, keep value briefly for correction diffing, then clear.
    if (!appState.imeMode) {
      _clearIME();
    } else {
      _scheduleClear();
    }
  });

  ime.addEventListener('compositioncancel' as keyof HTMLElementEventMap, () => {
    appState.isComposing = false;
    _imePreviewShow(null);
    _clearIME();
  });

  // ── keydown: special keys not captured by 'input' ─────────────────────
  ime.addEventListener('keydown', (e) => {
    // Reset password-mode suggestion suppression when user submits with Enter (#123)
    if (e.key === 'Enter') {
      ime.setAttribute('autocomplete', 'off');
      _clearIME();
    }

    if (e.ctrlKey && !e.altKey && e.key.length === 1) {
      const code = e.key.toLowerCase().charCodeAt(0) - 96;
      if (code >= 1 && code <= 26) {
        sendSSHInput(String.fromCharCode(code));
        _clearIME();
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
      _clearIME();
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
      _clearIME();
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
