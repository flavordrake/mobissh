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
import { sendSSHInput } from './connection.js';
import { toast, focusIME } from './ui.js';
import { getKeyboardVisible } from './terminal.js';
import { reconstructFromBuffer } from './ime-fixup.js';

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

/**
 * Read clipboard content, supporting images via navigator.clipboard.read().
 * Prefers text/plain; converts images to base64 for piping on remote.
 * Falls back to readText() if clipboard.read() is not available.
 */
async function readClipboard(): Promise<string> {
  try {
    const items = await navigator.clipboard.read();
    for (const item of items) {
      if (item.types.includes('text/plain')) {
        const blob = await item.getType('text/plain');
        return await blob.text();
      }
      for (const type of item.types) {
        if (type.startsWith('image/')) {
          const blob = await item.getType(type);
          const bytes = new Uint8Array(await blob.arrayBuffer());
          let binary = '';
          const CHUNK = 8192;
          for (let i = 0; i < bytes.length; i += CHUNK) {
            binary += String.fromCharCode(...bytes.subarray(i, i + CHUNK));
          }
          toast('Pasted image as base64');
          return btoa(binary);
        }
      }
    }
  } catch {
    // clipboard.read() not permitted or unavailable — fall back to readText
    const text = await navigator.clipboard.readText();
    return text;
  }
  return '';
}

// ── Public API ───────────────────────────────────────────────────────────────

/** True while the selection action chip is visible or a selection exists. */
export function isSelectionActive(): boolean {
  return _selectionActive;
}

/** Call once after terminal is created and DOM is ready. */
export function initSelection(): void {
  const termEl = document.getElementById('terminal')!;
  const chip = document.getElementById('selectionChip')!;
  const copyBtn = document.getElementById('handleCopyBtn')!;
  const pasteBtn = document.getElementById('handlePasteBtn')!;

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
    if ((e.target as HTMLElement).closest('#selectionChip')) return;
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

  // ── Action chip buttons ──────────────────────────────────────────────────

  document.getElementById('selectionPasteBtn')!.addEventListener('click', (e) => {
    e.stopPropagation();
    void readClipboard().then((text) => {
      if (text) sendSSHInput(text);
      else toast('Clipboard empty');
    }).catch(() => { toast('Paste failed'); });
    _hideChip();
  });

  document.getElementById('selectionVisibleBtn')!.addEventListener('click', (e) => {
    e.stopPropagation();
    const visTerm = currentSession()?.terminal;
    if (!visTerm) return;
    const buf = visTerm.buffer.active;
    visTerm.selectLines(buf.viewportY, buf.viewportY + visTerm.rows - 1);
    _hideChip();
  });

  document.getElementById('selectionAllBtn')!.addEventListener('click', (e) => {
    e.stopPropagation();
    const allTerm = currentSession()?.terminal;
    if (!allTerm) return;
    allTerm.selectAll();
    _hideChip();
  });

  document.getElementById('selectionDismissBtn')!.addEventListener('click', (e) => {
    e.stopPropagation();
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
        .then(() => { toast('Copied'); _showPasteIfClipboard(); })
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

  // ── Paste button on handle bar ──────────────────────────────────────────
  // Replaces the native OS paste chip we suppressed via contextmenu preventDefault.

  pasteBtn.addEventListener('click', (e) => {
    e.stopPropagation();
    void readClipboard().then((text) => {
      if (text) sendSSHInput(text);
      else toast('Clipboard empty');
    }).catch(() => { toast('Paste failed'); });
    _dismissSelection();
  });

  // Show paste button when long-press activates selection (clipboard likely has content)
  // and when selection is dismissed (user may want to paste after copying).
  function _showPasteIfClipboard(): void {
    // Try clipboard.read() first to detect images; fall back to readText()
    void (async () => {
      try {
        const items = await navigator.clipboard.read();
        let hasContent = false;
        let hasImage = false;
        for (const item of items) {
          if (item.types.includes('text/plain')) { hasContent = true; break; }
          for (const type of item.types) {
            if (type.startsWith('image/')) { hasContent = true; hasImage = true; break; }
          }
          if (hasContent) break;
        }
        pasteBtn.classList.toggle('hidden', !hasContent);
        pasteBtn.textContent = hasImage ? 'Paste (image)' : 'Paste';
      } catch {
        // clipboard.read() not available — fall back to readText
        try {
          const text = await navigator.clipboard.readText();
          pasteBtn.classList.toggle('hidden', !text);
          pasteBtn.textContent = 'Paste';
        } catch {
          pasteBtn.classList.add('hidden');
        }
      }
    })();
  }

  // ── Back gesture / hardware back → dismiss chip ───────────────────────────
  // When back fires, the browser already popped our {selectionChip} entry.
  // We just need to dismiss without calling history.back() again.
  window.addEventListener('popstate', () => {
    if (_selectionActive) {
      _selectionActive = false;
      _hideChip();
      currentSession()?.terminal?.clearSelection();
      copyBtn.classList.add('hidden');
      pasteBtn.classList.add('hidden');
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
    _keyboardWasVisible = getKeyboardVisible();
    try { navigator.vibrate(30); } catch { /* vibrate not available */ }
    // Blur the focused IME input. If the user had dismissed the keyboard,
    // the textarea still held focus — touching the terminal would re-summon
    // the keyboard mid-selection, resize the viewport, and invalidate the
    // drag anchor. Blur decouples the touch from the keyboard.
    // _dismissSelection restores focus via focusIME() only when the keyboard
    // was visible at start — so blur here is reversible.
    if (document.activeElement instanceof HTMLElement) {
      document.activeElement.blur();
    }
    _showPasteIfClipboard();
    chip.classList.remove('hidden');
    // Push history entry so Android back gesture dismisses the chip
    history.pushState({ selectionChip: true }, '');
  }

  function _hideChip(): void {
    chip.classList.add('hidden');
  }

  function _dismissSelection(): void {
    if (!_selectionActive) return;
    _selectionActive = false;
    _dragActive = false;
    _hideChip();
    currentSession()?.terminal?.clearSelection();
    copyBtn.classList.add('hidden');
    pasteBtn.classList.add('hidden');
    // Pop the history entry we pushed (unless back gesture already did it)
    if (history.state != null && (history.state as Record<string, unknown>).selectionChip === true) {
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
    dragTerm.select(startCol, startRow, len);
    _selectionLevel = 'unit';
    _anchorCol = pos.col;
    _anchorRow = pos.row;
    _dragActive = true;
  }

  /** Extend selection from anchor to current touch position. */
  function _extendDragSelect(clientX: number, clientY: number): void {
    const extTerm = currentSession()?.terminal;
    if (!_dragActive || !extTerm) return;
    _hideChip();
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
    const sel = currentSession()?.terminal?.getSelection();
    if (sel) {
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
