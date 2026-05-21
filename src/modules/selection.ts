/**
 * modules/selection.ts — Mobile text selection (#55)
 *
 * Phase 1: Long-press shows action chip (Paste, Select Visible, Select All).
 * Phase 2: Long-press word-selects at touch position via terminal.select() API.
 *          Dragging after long-press extends selection by recomputing the range.
 *
 * xterm.js has no native touch selection support (see xtermjs/xterm.js#5377).
 * Synthetic mouse events (dispatchEvent + MouseEvent) don't produce selections
 * because xterm's internal coordinate resolution fails for programmatic events.
 * Instead we compute buffer coordinates from touch position and call
 * terminal.select(column, row, length) directly.
 *
 * Uses xterm.js's built-in selection rendering — selection is drawn on the
 * canvas using the theme's selectionBackground. No DOM overlay.
 */

import { currentSession } from './state.js';
import { toast, focusIME } from './ui.js';
import { getKeyboardVisible } from './terminal.js';
import { reconstructFromBuffer } from './ime-fixup.js';
import { logGesture } from './gesture-log.js';
import { getIMEState } from './ime.js';
import { uploadGestureAnomaly } from './drop-telemetry.js';

// ── State ────────────────────────────────────────────────────────────────────

// ── Gesture-window diagnostic state (#502) ──────────────────────────────────
// A "gesture window" spans from touchstart on #terminal until 2s after
// touchend. While the window is active, capturing focusin/focusout listeners
// and a visualViewport.resize listener record events with timestamps relative
// to gesture start. ALL listeners are passive observers — no focus state
// mutation, no preventDefault on focus events.
//
// The 2s tail catches delayed IME show events that fire after touchend.
//
// At window close, if any anomaly condition triggers, uploadGestureAnomaly()
// is called (throttled). Conditions:
//   - any gesture_focusin with isHelper=true
//   - any gesture_viewport_resize with |deltaH| > 100
//   - imeState changed between touchstart snapshot and window close
let _gestureWindowActive = false;
let _gestureWindowStart = 0;
let _gestureWindowEndTimer: ReturnType<typeof setTimeout> | null = null;
let _gestureAuditTimer: ReturnType<typeof setInterval> | null = null;
let _gestureFocusinListener: ((e: FocusEvent) => void) | null = null;
let _gestureFocusoutListener: ((e: FocusEvent) => void) | null = null;
let _gestureVVResizeListener: ((e: Event) => void) | null = null;
let _gestureVVPrevHeight = 0;
let _gestureImeStateAtStart: string = 'idle';
let _gestureHelperFocusInCount = 0;
let _gestureLargeResizeCount = 0;
let _gestureEventCount = 0;

let _selectionActive = false;
let _longPressTimer: ReturnType<typeof setTimeout> | null = null;
let _dragActive = false;  // true while finger is down after long-press triggered
let _touchAnchorX = 0;
let _touchAnchorY = 0;
/** Buffer coordinates of drag-select anchor (set on long-press). */
let _anchorCol = 0;
let _anchorRow = 0;
/** Tracks selection granularity: 'unit' = URL/path, 'word' = single word. */
let _selectionLevel: 'unit' | 'word' = 'unit';
/** Whether the keyboard was visible when the current selection started. */
let _keyboardWasVisible = false;

const LONG_PRESS_MS = 500;
const LONG_PRESS_MOVE_THRESHOLD = 10; // px

// ── Public API ───────────────────────────────────────────────────────────────

/** True while the selection action chip is visible or a selection exists. */
export function isSelectionActive(): boolean {
  return _selectionActive;
}

// ── Gesture-window helpers (#502 diagnostic) ────────────────────────────────

/** Truncate any string-coerced className to 80 chars. SVG-element className is
 *  a `SVGAnimatedString`, not a string — so coerce defensively. */
function _classOf(el: Element | null): string {
  if (!el) return '';
  try {
    const c = (el as { className?: unknown }).className;
    if (typeof c === 'string') return c.slice(0, 80);
    if (c && typeof (c as { baseVal?: string }).baseVal === 'string') {
      return (c as { baseVal: string }).baseVal.slice(0, 80);
    }
  } catch { /* fall through */ }
  return '';
}

/** Capture a 6-frame stack trace at event-time. Browsers vary in how much
 *  of the dispatcher's frames they preserve; Chrome typically keeps enough
 *  to identify which library called .focus(). Anonymous-only frames are
 *  dropped. */
function _captureStack(): string | null {
  try {
    const e = new Error('stack-probe');
    if (!e.stack) return null;
    const lines = e.stack.split('\n').map((s) => s.trim());
    // Drop the first frame ("Error: stack-probe") and our own helper frame.
    const filtered = lines
      .slice(1)
      .filter((l) => l.length > 0 && !l.includes('_captureStack'))
      .filter((l) => !/^at\s+(<anonymous>|\(<anonymous>\))$/.test(l));
    return filtered.slice(0, 6).join('\n');
  } catch {
    return null;
  }
}

function _safeGetIMEState(): string {
  try { return getIMEState(); } catch { return 'unknown'; }
}

function _helperFocusAuditSnapshot(): Record<string, unknown> {
  try {
    const active = document.activeElement;
    const helper = document.querySelector<HTMLTextAreaElement>('.xterm-helper-textarea');
    return {
      activeId: active instanceof Element ? (active.id || '') : '',
      activeClass: _classOf(active),
      activeTag: active instanceof Element ? active.tagName.toLowerCase() : '',
      helperTabIndex: helper ? helper.tabIndex : null,
      helperInputMode: helper ? helper.inputMode : null,
      helperReadOnly: helper ? helper.readOnly : null,
      helperPresent: !!helper,
    };
  } catch (err) {
    return { auditError: (err as Error).message };
  }
}

function _openGestureWindow(): void {
  if (_gestureWindowActive) {
    // Already inside a window (touchstart fired again before tail expired).
    // Cancel any pending close and refresh start time only if we'd otherwise
    // close. Keep the original gesture-start so deltas remain meaningful.
    if (_gestureWindowEndTimer !== null) {
      clearTimeout(_gestureWindowEndTimer);
      _gestureWindowEndTimer = null;
    }
    return;
  }
  _gestureWindowActive = true;
  _gestureWindowStart = performance.now();
  _gestureHelperFocusInCount = 0;
  _gestureLargeResizeCount = 0;
  _gestureEventCount = 0;
  _gestureImeStateAtStart = _safeGetIMEState();
  try {
    const vv = window.visualViewport;
    _gestureVVPrevHeight = vv?.height ?? window.innerHeight;
  } catch { _gestureVVPrevHeight = window.innerHeight; }

  // Initial audit snapshot.
  try {
    logGesture('gesture_helper_focus_audit', {
      ..._helperFocusAuditSnapshot(),
      t: 0,
      trigger: 'touchstart',
    });
  } catch { /* log must not throw */ }

  // Install passive observers.
  _gestureFocusinListener = (e: FocusEvent): void => {
    try {
      const target = e.target as Element | null;
      const id = target instanceof Element ? (target.id || '') : '';
      const cls = _classOf(target);
      const isHelper = cls.includes('xterm-helper-textarea');
      const isOurs = id === 'imeInput' || id === 'directInput';
      if (isHelper) _gestureHelperFocusInCount++;
      _gestureEventCount++;
      const vv = window.visualViewport;
      logGesture('gesture_focusin', {
        t: Math.round(performance.now() - _gestureWindowStart),
        targetId: id,
        targetClass: cls,
        isHelper,
        isOurs,
        imeState: _safeGetIMEState(),
        selectionActive: _selectionActive,
        vvHeight: vv?.height ?? null,
        vvScale: vv?.scale ?? null,
        innerHeight: window.innerHeight,
        stack: _captureStack(),
      });
    } catch (err) {
      try { logGesture('gesture_listener_error', { where: 'focusin', err: (err as Error).message }); } catch { /* */ }
    }
  };

  _gestureFocusoutListener = (e: FocusEvent): void => {
    try {
      const target = e.target as Element | null;
      const id = target instanceof Element ? (target.id || '') : '';
      const cls = _classOf(target);
      const isHelper = cls.includes('xterm-helper-textarea');
      const isOurs = id === 'imeInput' || id === 'directInput';
      _gestureEventCount++;
      const vv = window.visualViewport;
      logGesture('gesture_focusout', {
        t: Math.round(performance.now() - _gestureWindowStart),
        targetId: id,
        targetClass: cls,
        isHelper,
        isOurs,
        imeState: _safeGetIMEState(),
        selectionActive: _selectionActive,
        vvHeight: vv?.height ?? null,
        vvScale: vv?.scale ?? null,
        innerHeight: window.innerHeight,
        stack: _captureStack(),
      });
    } catch (err) {
      try { logGesture('gesture_listener_error', { where: 'focusout', err: (err as Error).message }); } catch { /* */ }
    }
  };

  _gestureVVResizeListener = (): void => {
    try {
      const vv = window.visualViewport;
      if (!vv) return;
      const h = vv.height;
      const w = vv.width;
      const scale = vv.scale;
      const deltaH = h - _gestureVVPrevHeight;
      _gestureVVPrevHeight = h;
      if (Math.abs(deltaH) > 100) _gestureLargeResizeCount++;
      _gestureEventCount++;
      logGesture('gesture_viewport_resize', {
        t: Math.round(performance.now() - _gestureWindowStart),
        h,
        w,
        scale,
        deltaH,
      });
    } catch (err) {
      try { logGesture('gesture_listener_error', { where: 'vv_resize', err: (err as Error).message }); } catch { /* */ }
    }
  };

  document.addEventListener('focusin', _gestureFocusinListener, true);
  document.addEventListener('focusout', _gestureFocusoutListener, true);
  try {
    window.visualViewport?.addEventListener('resize', _gestureVVResizeListener);
  } catch { /* visualViewport unavailable in some environments */ }

  // Periodic helper-focus audit while gesture window is active.
  _gestureAuditTimer = setInterval(() => {
    try {
      logGesture('gesture_helper_focus_audit', {
        ..._helperFocusAuditSnapshot(),
        t: Math.round(performance.now() - _gestureWindowStart),
        trigger: 'periodic',
      });
    } catch { /* */ }
  }, 5000);
}

function _scheduleGestureWindowClose(): void {
  if (!_gestureWindowActive) return;
  if (_gestureWindowEndTimer !== null) {
    clearTimeout(_gestureWindowEndTimer);
  }
  _gestureWindowEndTimer = setTimeout(_closeGestureWindow, 2000);
}

function _closeGestureWindow(): void {
  if (!_gestureWindowActive) return;
  _gestureWindowActive = false;
  _gestureWindowEndTimer = null;

  if (_gestureFocusinListener) {
    document.removeEventListener('focusin', _gestureFocusinListener, true);
    _gestureFocusinListener = null;
  }
  if (_gestureFocusoutListener) {
    document.removeEventListener('focusout', _gestureFocusoutListener, true);
    _gestureFocusoutListener = null;
  }
  if (_gestureVVResizeListener) {
    try { window.visualViewport?.removeEventListener('resize', _gestureVVResizeListener); } catch { /* */ }
    _gestureVVResizeListener = null;
  }
  if (_gestureAuditTimer !== null) {
    clearInterval(_gestureAuditTimer);
    _gestureAuditTimer = null;
  }

  // Evaluate anomaly conditions. Pick the most-specific reason if multiple
  // conditions fire (helper-focus is the strongest signal for #502).
  try {
    const imeStateAtClose = _safeGetIMEState();
    const imeChanged = imeStateAtClose !== _gestureImeStateAtStart;
    const helperFocused = _gestureHelperFocusInCount > 0;
    const largeResize = _gestureLargeResizeCount > 0;
    if (helperFocused || largeResize || imeChanged) {
      let reason = 'unknown';
      if (helperFocused) reason = 'focus_during_long_press';
      else if (largeResize) reason = 'viewport_resize_during_gesture';
      else if (imeChanged) reason = 'ime_state_changed_during_gesture';
      uploadGestureAnomaly(reason, _gestureEventCount);
    }
  } catch (err) {
    try { logGesture('gesture_listener_error', { where: 'window_close', err: (err as Error).message }); } catch { /* */ }
  }
}

/** Test-only: force-close the gesture window immediately. Exported for
 *  vitest. Not part of the runtime selection API. */
export function _testCloseGestureWindow(): void {
  if (_gestureWindowEndTimer !== null) {
    clearTimeout(_gestureWindowEndTimer);
    _gestureWindowEndTimer = null;
  }
  _closeGestureWindow();
}

/** Test-only: open a gesture window without a real touchstart. Exported for
 *  vitest. */
export function _testOpenGestureWindow(): void {
  _openGestureWindow();
}

/** Call once after terminal is created and DOM is ready. */
export function initSelection(): void {
  const termEl = document.getElementById('terminal')!;
  const copyBtn = document.getElementById('handleCopyBtn')!;

  // ── Suppress native context menu on terminal (#55) ─────────────────────
  // Prevents OS paste chip, "Open URL" menu, and other native long-press UI
  // that conflicts with our custom selection system.
  termEl.addEventListener('contextmenu', (e) => { e.preventDefault(); });

  // ── Suppress xterm.js's rightClickHandler on touch-derived mousedown (#502) ──
  // Telemetry trace (2026-05-21T20:49) showed: on long-press with keyboard
  // visible, Android Chrome synthesises mousedown from the touch; xterm.js's
  // capture-phase listener calls `t.rightClickHandler` which focuses the
  // .xterm-helper-textarea; that focus shift causes Android to dismiss the
  // soft keyboard (which the user reports as "keyboard disappeared on
  // long-press"). Stack: _gestureFocusinListener ← n ← t.rightClickHandler
  // ← HTMLDivElement.<anonymous> (xterm.min.js:7:16568).
  //
  // Fix: gate any mousedown that arrives within 600ms of a touchstart on
  // #terminal. Stop propagation in the capture phase so xterm's listener
  // never runs. Desktop mouse interaction is unaffected (no touchstart
  // precedes a real mouse click). Our own selection.ts long-press path is
  // unaffected (it's keyed off touchstart/touchmove/touchend, never
  // mousedown).
  let _lastTouchstartOnTerm = 0;
  termEl.addEventListener('touchstart', () => {
    _lastTouchstartOnTerm = performance.now();
  }, { passive: true, capture: true });
  termEl.addEventListener('mousedown', (e) => {
    if (performance.now() - _lastTouchstartOnTerm < 600) {
      e.stopImmediatePropagation();
    }
  }, { capture: true });

  // ── Long-press detection + drag-to-select (Phase 2) ─────────────────────

  termEl.addEventListener('touchstart', (e) => {
    if (e.touches.length !== 1) return;
    _touchAnchorX = e.touches[0]!.clientX;
    _touchAnchorY = e.touches[0]!.clientY;
    // Open the gesture diagnostic window (#502 — passive observers, no
    // focus-state mutation). Listeners gated by _gestureWindowActive close
    // 2s after touchend so delayed IME-show events are captured.
    try { _openGestureWindow(); } catch { /* diagnostic must not break gestures */ }
    _longPressTimer = setTimeout(() => {
      _longPressTimer = null;
      _onLongPress();
      // Phase 2: word-select at touch position via synthetic mousedown
      _startDragSelect(_touchAnchorX, _touchAnchorY);
    }, LONG_PRESS_MS);
  }, { passive: true });

  termEl.addEventListener('touchmove', (e) => {
    // Phase 2: extend selection while dragging after long-press
    if (_dragActive) {
      const tx = e.touches[0]!.clientX;
      const ty = e.touches[0]!.clientY;
      _extendDragSelect(tx, ty);
      return;
    }
    if (_longPressTimer === null) return;
    const dx = e.touches[0]!.clientX - _touchAnchorX;
    const dy = e.touches[0]!.clientY - _touchAnchorY;
    if (Math.abs(dx) > LONG_PRESS_MOVE_THRESHOLD || Math.abs(dy) > LONG_PRESS_MOVE_THRESHOLD) {
      clearTimeout(_longPressTimer);
      _longPressTimer = null;
    }
  }, { passive: true });

  termEl.addEventListener('touchend', () => {
    if (_longPressTimer !== null) {
      clearTimeout(_longPressTimer);
      _longPressTimer = null;
    }
    // Phase 2: finalize drag-select on finger up
    if (_dragActive) {
      _endDragSelect();
    }
    // Schedule the gesture-window close 2s after touchend (catches delayed
    // IME show events that fire after touchend on Android Chrome).
    try { _scheduleGestureWindowClose(); } catch { /* */ }
  }, { passive: true });

  // Tap while selection active: contract unit→word, then word→dismiss
  termEl.addEventListener('click', (e) => {
    if (!_selectionActive) return;
    if (_selectionLevel === 'unit') {
      // Contract URL/path selection down to just the word at tap position
      const pos = _touchToBufferPos(e.clientX, e.clientY);
      const term = currentSession()?.terminal;
      if (pos && term) {
        const [startCol, startRow, len] = _wordAt(pos.row, pos.col);
        term.select(startCol, startRow, len);
        _selectionLevel = 'word';
        return;
      }
    }
    _dismissSelection();
  });

  /** Reconstruct the current selection using xterm's `isWrapped` metadata so
   *  soft-wrapped URLs / commands / API keys round-trip into one line. Falls
   *  back to the raw `getSelection()` string only if buffer access fails. */
  function _selectionTextWrapAware(): string {
    const term = currentSession()?.terminal;
    if (!term) return '';
    try {
      // Cast: xterm's internal types match our structural ITerminalLike.
      const range = (term as unknown as { getSelectionPosition(): { start: { x: number; y: number }; end: { x: number; y: number } } | undefined }).getSelectionPosition();
      if (range) {
        return reconstructFromBuffer(term as unknown as Parameters<typeof reconstructFromBuffer>[0], range);
      }
    } catch (err) {
      console.warn('[selection] wrap-aware reconstruction failed:', err);
    }
    return term.getSelection();
  }

  // ── Copy button on handle bar ────────────────────────────────────────────

  copyBtn.addEventListener('click', (e) => {
    e.stopPropagation();
    const sel = _selectionTextWrapAware();
    if (sel) {
      void navigator.clipboard.writeText(sel)
        .then(() => { toast('Copied'); })
        .catch(() => { toast('Copy failed'); });
    }
    _dismissSelection();
  });

  // ── Copy event interception (desktop Cmd+C / Ctrl+C) ─────────────────────
  // xterm renders to canvas; selection is xterm's own state, not a real
  // browser Selection. The native `copy` event fires with empty data for the
  // helper textarea — we intercept and substitute the wrap-aware text so
  // desktop keyboard copy and the handle button both produce identical
  // output.
  document.addEventListener('copy', (e) => {
    const term = currentSession()?.terminal;
    if (!term?.hasSelection()) return;
    const text = _selectionTextWrapAware();
    if (!text) return;
    e.preventDefault();
    e.clipboardData?.setData('text/plain', text);
  });


  // ── Back gesture / hardware back → dismiss selection ──────────────────────
  // When back fires, the browser already popped our selection history entry.
  // We just need to dismiss without calling history.back() again.
  window.addEventListener('popstate', () => {
    if (_selectionActive) {
      _selectionActive = false;
      currentSession()?.terminal?.clearSelection();
      copyBtn.classList.add('hidden');
      if (_keyboardWasVisible) setTimeout(focusIME, 50);
    }
  });

  // ── onSelectionChange → show/hide copy button ────────────────────────────
  // Re-register whenever terminal is recreated; for now, poll via a one-shot
  // setup. The terminal is already created when initSelection() is called.

  _watchSelection(copyBtn);

  // ── Helpers ──────────────────────────────────────────────────────────────

  function _onLongPress(): void {
    _selectionActive = true;
    // Read keyboard visibility INLINE from visualViewport — the cached
    // `getKeyboardVisible()` flag in terminal.ts can go stale (a back-gesture
    // dismiss may not fire visualViewport.resize, leaving cache=true while
    // keyboard is actually hidden). Bug-report 2026-05-05T01-53-59 caught
    // exactly that: touchstart's inline check said hidden, long-press's
    // cached check said visible — they should agree. Stale cache made us
    // skip the blur, then xterm's `term.select()` re-focused its helper
    // textarea and summoned the keyboard. Use the inline reading.
    const vv = window.visualViewport;
    const kbVisibleNow = !!vv && vv.height < window.innerHeight - 100;
    _keyboardWasVisible = kbVisibleNow;
    logGesture('gesture_long_press', {
      keyboardVisible: kbVisibleNow,
      cachedKeyboardVisible: getKeyboardVisible(),
    });
    try { navigator.vibrate(30); } catch { /* vibrate not available */ }
    // Conditional blur. If the keyboard was HIDDEN but the textarea still
    // had focus (user dismissed via back button), blur to prevent the
    // terminal touch from re-summoning the keyboard mid-select. If the
    // keyboard was already VISIBLE, do NOT blur — blurring dismisses the
    // keyboard, which fires a viewport resize during the drag-select
    // gesture, shifts the buffer-coordinate anchor, and produces a wrong
    // selection. The user reported the regression directly: "long pressing
    // when keyboard is visible dismisses the keyboard, resizes the screen,
    // and tapping again re-activates it."
    // _dismissSelection's focusIME restore is gated on _keyboardWasVisible,
    // so leaving focus intact here stays consistent with that path.
    if (!kbVisibleNow && document.activeElement instanceof HTMLElement) {
      document.activeElement.blur();
    }
    // Push a history entry so Android back gesture dismisses the selection.
    history.pushState({ selectionActive: true }, '');
  }

  function _dismissSelection(): void {
    if (!_selectionActive) return;
    _selectionActive = false;
    _dragActive = false;
    currentSession()?.terminal?.clearSelection();
    copyBtn.classList.add('hidden');
    // Pop the history entry we pushed (unless back gesture already did it)
    if (history.state != null && (history.state as Record<string, unknown>).selectionActive === true) {
      history.back();
    }
    // Only restore keyboard focus if it was visible when selection started.
    // If the user had dismissed the keyboard before long-pressing, don't re-show it.
    if (_keyboardWasVisible) setTimeout(focusIME, 50);
  }

  // ── Phase 2: Direct terminal.select() for drag-to-select ───────────────
  // xterm.js synthetic mouse events don't produce selections (xtermjs#5377).
  // Instead we map touch CSS coords → buffer col/row and call select() directly.

  /** Convert CSS client coordinates to {col, bufferRow} in the terminal. */
  function _touchToBufferPos(clientX: number, clientY: number): { col: number; row: number } | null {
    const term = currentSession()?.terminal;
    if (!term) return null;
    const screen = term.element?.querySelector('.xterm-screen');
    if (!screen) return null;
    const rect = screen.getBoundingClientRect();
    const relX = clientX - rect.left;
    const relY = clientY - rect.top;
    const cellW = rect.width / term.cols;
    const cellH = rect.height / term.rows;
    const col = Math.max(0, Math.min(term.cols - 1, Math.floor(relX / cellW)));
    const viewportRow = Math.max(0, Math.min(term.rows - 1, Math.floor(relY / cellH)));
    const bufferRow = viewportRow + term.buffer.active.viewportY;
    return { col, row: bufferRow };
  }

  /**
   * Get the logical line spanning wrapped rows. Returns the concatenated text,
   * the first buffer row, and the column count per row.
   */
  function _getLogicalLine(bufferRow: number): { text: string; firstRow: number; cols: number } {
    const term = currentSession()?.terminal;
    if (!term) return { text: '', firstRow: bufferRow, cols: 1 };
    const buf = term.buffer.active;
    const cols = term.cols;
    // Walk backward to first non-wrapped row
    let firstRow = bufferRow;
    while (firstRow > 0) {
      const prev = buf.getLine(firstRow);
      if (!prev || !prev.isWrapped) break;
      firstRow--;
    }
    // Walk forward collecting wrapped rows
    let text = '';
    let r = firstRow;
    while (r < buf.length) {
      const row = buf.getLine(r);
      if (!row) break;
      if (r > firstRow && !row.isWrapped) break;
      text += row.translateToString(false);
      r++;
    }
    return { text, firstRow, cols };
  }

  /**
   * Find selectable unit at column in a buffer line. Returns [startCol, startRow, length].
   * Priority: URL > path > word. URLs and paths are the most common copy targets.
   * Handles URLs that wrap across multiple terminal rows.
   */
  function _selectableUnitAt(bufferRow: number, col: number): [number, number, number] {
    const term = currentSession()?.terminal;
    if (!term) return [col, bufferRow, 1];

    // Build the full logical line (joining wrapped rows)
    const { text, firstRow, cols } = _getLogicalLine(bufferRow);
    if (!text) return [col, bufferRow, 1];

    // Position within the logical line
    const logicalCol = (bufferRow - firstRow) * cols + col;

    // Try URL first
    const urlRe = /https?:\/\/[^\s"'<>()]+|[a-z]+:\/\/[^\s"'<>()]+/gi;
    let m: RegExpExecArray | null;
    while ((m = urlRe.exec(text)) !== null) {
      if (logicalCol >= m.index && logicalCol < m.index + m[0].length) {
        const startRow = firstRow + Math.floor(m.index / cols);
        const startCol = m.index % cols;
        return [startCol, startRow, m[0].length];
      }
    }

    // Try file path: /foo/bar or ~/foo or ./foo
    const pathRe = /(?:~\/|\.\/|\/)[^\s"'<>():|]+/g;
    while ((m = pathRe.exec(text)) !== null) {
      if (logicalCol >= m.index && logicalCol < m.index + m[0].length) {
        const startRow = firstRow + Math.floor(m.index / cols);
        const startCol = m.index % cols;
        return [startCol, startRow, m[0].length];
      }
    }

    // Fall back to word (non-whitespace run) on the logical line
    const isWordChar = (c: string): boolean => c !== ' ' && c !== '\u0000' && c.trim().length > 0;
    if (!isWordChar(text[logicalCol] ?? ' ')) return [col, bufferRow, 1];
    let start = logicalCol;
    while (start > 0 && isWordChar(text[start - 1] ?? ' ')) start--;
    let end = logicalCol;
    while (end < text.length - 1 && isWordChar(text[end + 1] ?? ' ')) end++;
    const startRow = firstRow + Math.floor(start / cols);
    const startCol = start % cols;
    return [startCol, startRow, end - start + 1];
  }

  /** Word-only select (no URL/path expansion). Used for tap-to-contract.
   *  Uses tighter word boundaries that break on URL/path delimiters so
   *  contracting a URL selects a path segment, not the entire URL. */
  function _wordAt(bufferRow: number, col: number): [number, number, number] {
    const term = currentSession()?.terminal;
    if (!term) return [col, bufferRow, 1];
    const { text, firstRow, cols } = _getLogicalLine(bufferRow);
    if (!text) return [col, bufferRow, 1];
    const logicalCol = (bufferRow - firstRow) * cols + col;
    // Break on whitespace, null, and URL/path delimiters
    const DELIMITERS = new Set([' ', '\u0000', '\t', '/', '?', '&', '=', ':', '%', '#', '@', ';']);
    const isWordChar = (c: string): boolean => !DELIMITERS.has(c) && c.trim().length > 0;
    if (!isWordChar(text[logicalCol] ?? ' ')) return [col, bufferRow, 1];
    let start = logicalCol;
    while (start > 0 && isWordChar(text[start - 1] ?? ' ')) start--;
    let end = logicalCol;
    while (end < text.length - 1 && isWordChar(text[end + 1] ?? ' ')) end++;
    const startRow = firstRow + Math.floor(start / cols);
    const startCol = start % cols;
    return [startCol, startRow, end - start + 1];
  }

  /** Word/URL-select at touch position. Called on long-press. */
  function _startDragSelect(clientX: number, clientY: number): void {
    const pos = _touchToBufferPos(clientX, clientY);
    const dragTerm = currentSession()?.terminal;
    if (!pos || !dragTerm) return;
    const [startCol, startRow, len] = _selectableUnitAt(pos.row, pos.col);
    // Suppress the soft keyboard on `.xterm-helper-textarea` BEFORE
    // term.select() focuses it. xterm.js's select() synchronously focuses
    // its hidden helper textarea so Cmd+C / Ctrl+C can copy the selection.
    // On Android Chrome, that focus queues an IME-show task; even a
    // synchronous helper.blur() afterwards can leave the IME visible for
    // a frame (#502 Appium B1 caught vv.height: 806→436 mid-gesture).
    // Setting inputmode="none" on the helper tells Android Chrome to
    // NEVER show an IME for it, so the focus is silent — keyboard state
    // doesn't change regardless of whether it was up or dismissed. Cmd+C
    // on desktop still works (focus is unaffected; only IME is suppressed).
    const root = dragTerm.element ?? document;
    const helper = root.querySelector<HTMLTextAreaElement>('.xterm-helper-textarea');
    if (helper && helper.inputMode !== 'none') {
      helper.inputMode = 'none';
    }
    dragTerm.select(startCol, startRow, len);
    // Defensive blur — if a future xterm.js update changes the focus
    // behavior, this still keeps focus off helper.
    helper?.blur();
    _selectionLevel = 'unit';
    _anchorCol = pos.col;
    _anchorRow = pos.row;
    _dragActive = true;
    logGesture('gesture_drag_select_start', { col: startCol, row: startRow, len });
  }

  /** Extend selection from anchor to current touch position. */
  function _extendDragSelect(clientX: number, clientY: number): void {
    const extTerm = currentSession()?.terminal;
    if (!_dragActive || !extTerm) return;
    const pos = _touchToBufferPos(clientX, clientY);
    if (!pos) return;
    // Determine start and end in buffer order
    let startCol: number, startRow: number, endCol: number, endRow: number;
    if (pos.row < _anchorRow || (pos.row === _anchorRow && pos.col < _anchorCol)) {
      startCol = pos.col; startRow = pos.row;
      endCol = _anchorCol; endRow = _anchorRow;
    } else {
      startCol = _anchorCol; startRow = _anchorRow;
      endCol = pos.col; endRow = pos.row;
    }
    if (startRow === endRow) {
      extTerm.select(startCol, startRow, endCol - startCol + 1);
    } else {
      // Multi-line: select from startCol to end of startRow, full middle rows,
      // start of endRow to endCol. Use selectLines for simplicity, then we can
      // refine later if character-level multi-line is needed.
      extTerm.selectLines(startRow, endRow);
    }
  }

  /** Finalize selection on finger up. */
  function _endDragSelect(): void {
    if (!_dragActive) return;
    _dragActive = false;
    const sel = currentSession()?.terminal?.getSelection() ?? '';
    logGesture('gesture_drag_select_end', { len: sel.length });
    // Selection stays visible; copy button handled by _watchSelection
  }
}

// ── Selection watcher ────────────────────────────────────────────────────────

/** Track which terminal we've bound to, so we re-bind on session switch. */
let _watchedTerminal: Terminal | null = null;

function _watchSelection(copyBtn: HTMLElement): void {
  const watchTerm = currentSession()?.terminal ?? null;
  if (!watchTerm || watchTerm === _watchedTerminal) return;
  _watchedTerminal = watchTerm;
  watchTerm.onSelectionChange(() => {
    // Use `hasSelection()` (predicate) rather than `getSelection()` (text).
    // The text getter returns whitespace-only strings for selections that
    // span only spaces/empty cells, and on some xterm versions the change
    // event fires once with an empty string mid-transition before settling.
    // Either case left the Copy button hidden for legitimate selections —
    // particularly small partial-line selections. `hasSelection()` reports
    // any visible highlight regardless of content.
    const term = currentSession()?.terminal;
    if (term?.hasSelection()) {
      _selectionActive = true;
      copyBtn.classList.remove('hidden');
    } else {
      copyBtn.classList.add('hidden');
    }
  });
}

/** Re-bind selection watcher after session switch. Call from switchSession(). */
export function rebindSelectionWatcher(): void {
  const copyBtn = document.getElementById('handleCopyBtn');
  if (copyBtn) _watchSelection(copyBtn);
}
