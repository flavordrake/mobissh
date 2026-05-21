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

// ── State ────────────────────────────────────────────────────────────────────

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

// ── Permanent helper-focus neutralization (#502) ─────────────────────
// The .xterm-helper-textarea exists for xterm.js's native Cmd+C copy
// path. On Android Chrome, ANY touch on the terminal area can trigger
// the helper to gain focus via native gesture handling (#502 Appium
// trace showed this fires even from measureScreenOffset's probe touch,
// before our _startDragSelect runs). That focus queues an IME-show
// task that fires ~250-470ms later regardless of any subsequent blur
// we do — Android sees the focusin event, decides "user is interacting
// with input," and shows the keyboard for whichever input is focused
// when the task executes.
//
// Mitigation: install a single, permanent, capture-phase focusin
// listener that blurs `.xterm-helper-textarea` IMMEDIATELY on any
// focus. The desktop Cmd+C path is unaffected because our
// document-level `copy` event handler provides wrap-aware clipboard
// text without needing the helper to be focused.
//
// Hoisted to module scope so initSelection() can call it before the
// `let` declaration is reached (calling a closure-scoped helper before
// its `let` is in TDZ and throws ReferenceError at app boot).
let _helperFocusGuardInstalled = false;
function _installHelperFocusGuard(): void {
  if (_helperFocusGuardInstalled) return;
  _helperFocusGuardInstalled = true;
  document.addEventListener('focusin', (e) => {
    const t = e.target;
    if (!(t instanceof HTMLElement)) return;
    if (typeof t.className === 'string' && t.className.indexOf('xterm-helper-textarea') >= 0) {
      t.blur();
    }
  }, { capture: true });
}

// ── Public API ───────────────────────────────────────────────────────────────

/** True while the selection action chip is visible or a selection exists. */
export function isSelectionActive(): boolean {
  return _selectionActive;
}

/** Call once after terminal is created and DOM is ready. */
export function initSelection(): void {
  const termEl = document.getElementById('terminal')!;
  const copyBtn = document.getElementById('handleCopyBtn')!;

  // Install the helper-focus guard immediately on init — any terminal
  // touch can trigger native focus on .xterm-helper-textarea, not just
  // our long-press handler. See #502.
  _installHelperFocusGuard();

  // ── Suppress native context menu on terminal (#55) ─────────────────────
  // Prevents OS paste chip, "Open URL" menu, and other native long-press UI
  // that conflicts with our custom selection system.
  termEl.addEventListener('contextmenu', (e) => { e.preventDefault(); });

  // ── Long-press detection + drag-to-select (Phase 2) ─────────────────────

  termEl.addEventListener('touchstart', (e) => {
    if (e.touches.length !== 1) return;
    _touchAnchorX = e.touches[0]!.clientX;
    _touchAnchorY = e.touches[0]!.clientY;
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
    // xterm.js's term.select() synchronously focuses
    // `.xterm-helper-textarea` (so Cmd+C can copy from a real textarea
    // node). On Android Chrome, that focus queues an IME-show task that
    // fires ~250ms later for whichever input is focused at that moment —
    // even if we blur the helper immediately, the browser auto-restores
    // focus to the most-recently-focused input (e.g. #directInput), so
    // the IME shows for THAT input ~250ms post-gesture and then dismisses.
    // See #502 Appium B1 trace at t=7567 (focusin helper) → t=7583
    // (focusin directInput, browser auto-restore) → t=7813 (vv.height
    // 806→436, IME-show fires).
    //
    // Mitigation: hold a focus "blackout" for ~300ms after term.select()
    // by blurring whichever element gains focus during that window. The
    // IME-show task sees no focused input and drops. We then let normal
    // focus management resume — _dismissSelection's focusIME restore
    // (gated on _keyboardWasVisible) handles the post-gesture state.
    // Permanent helper-focus guard does the heavy lifting. We still call
    // .blur() defensively in case a future xterm.js version sets focus
    // via a path the capture listener doesn't see.
    const root = dragTerm.element ?? document;
    const helper = root.querySelector<HTMLTextAreaElement>('.xterm-helper-textarea');
    dragTerm.select(startCol, startRow, len);
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
