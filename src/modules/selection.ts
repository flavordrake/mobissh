/**
 * modules/selection.ts — Mobile text selection (#55)
 *
 * Phase 1: Long-press shows action chip (Paste, Select Visible, Select All).
 * Phase 2: Long-press also word-selects at touch position via synthetic mouse
 *          events. Dragging after long-press extends the selection.
 *
 * When xterm.js has an active selection, a Copy button appears on the session
 * handle bar. Uses xterm.js's built-in selection system — selection is rendered
 * on the canvas using the theme's selectionBackground. No DOM overlay.
 */

import { appState } from './state.js';
import { sendSSHInput } from './connection.js';
import { toast, focusIME } from './ui.js';

// ── State ────────────────────────────────────────────────────────────────────

let _selectionActive = false;
let _longPressTimer: ReturnType<typeof setTimeout> | null = null;
let _dragActive = false;  // true while finger is down after long-press triggered
let _touchAnchorX = 0;
let _touchAnchorY = 0;

const LONG_PRESS_MS = 500;
const LONG_PRESS_MOVE_THRESHOLD = 10; // px

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

  // Dismiss chip on tap outside it (but inside terminal)
  termEl.addEventListener('click', (e) => {
    if (_selectionActive && !(e.target as HTMLElement).closest('#selectionChip')) {
      _dismissSelection();
    }
  });

  // ── Action chip buttons ──────────────────────────────────────────────────

  document.getElementById('selectionPasteBtn')!.addEventListener('click', (e) => {
    e.stopPropagation();
    void navigator.clipboard.readText().then((text) => {
      if (text) sendSSHInput(text);
      else toast('Clipboard empty');
    }).catch(() => { toast('Paste failed'); });
    _hideChip();
  });

  document.getElementById('selectionVisibleBtn')!.addEventListener('click', (e) => {
    e.stopPropagation();
    if (!appState.terminal) return;
    const buf = appState.terminal.buffer.active;
    appState.terminal.selectLines(buf.viewportY, buf.viewportY + appState.terminal.rows - 1);
    _hideChip();
  });

  document.getElementById('selectionAllBtn')!.addEventListener('click', (e) => {
    e.stopPropagation();
    if (!appState.terminal) return;
    appState.terminal.selectAll();
    _hideChip();
  });

  document.getElementById('selectionDismissBtn')!.addEventListener('click', (e) => {
    e.stopPropagation();
    _dismissSelection();
  });

  // ── Copy button on handle bar ────────────────────────────────────────────

  copyBtn.addEventListener('click', (e) => {
    e.stopPropagation();
    const sel = appState.terminal?.getSelection();
    if (sel) {
      void navigator.clipboard.writeText(sel)
        .then(() => { toast('Copied'); })
        .catch(() => { toast('Copy failed'); });
    }
    _dismissSelection();
  });

  // ── Back gesture / hardware back → dismiss chip ───────────────────────────
  // When back fires, the browser already popped our {selectionChip} entry.
  // We just need to dismiss without calling history.back() again.
  window.addEventListener('popstate', () => {
    if (_selectionActive) {
      _selectionActive = false;
      _hideChip();
      appState.terminal?.clearSelection();
      copyBtn.classList.add('hidden');
      setTimeout(focusIME, 50);
    }
  });

  // ── onSelectionChange → show/hide copy button ────────────────────────────
  // Re-register whenever terminal is recreated; for now, poll via a one-shot
  // setup. The terminal is already created when initSelection() is called.

  _watchSelection(copyBtn);

  // ── Helpers ──────────────────────────────────────────────────────────────

  function _onLongPress(): void {
    _selectionActive = true;
    try { navigator.vibrate(30); } catch { /* vibrate not available */ }
    // Blur IME to dismiss soft keyboard before showing chip
    if (document.activeElement instanceof HTMLElement) document.activeElement.blur();
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
    appState.terminal?.clearSelection();
    copyBtn.classList.add('hidden');
    // Pop the history entry we pushed (unless back gesture already did it)
    if (history.state != null && (history.state as Record<string, unknown>).selectionChip === true) {
      history.back();
    }
    setTimeout(focusIME, 50);
  }

  // ── Phase 2: Synthetic mouse events for drag-to-select ────────────────

  /** True if mouse tracking mode (DECSET 1000/1002/1006) is active. */
  function _isMouseTrackingActive(): boolean {
    // xterm.js adds 'enable-mouse-events' class when mouse protocol is on
    return appState.terminal?.element?.classList.contains('enable-mouse-events') ?? false;
  }

  /** Dispatch synthetic mousedown(detail:2) to word-select at touch coords. */
  function _startDragSelect(clientX: number, clientY: number): void {
    if (!appState.terminal?.element || _isMouseTrackingActive()) return;
    const target = appState.terminal.element;
    target.dispatchEvent(new MouseEvent('mousedown', {
      clientX, clientY,
      button: 0, buttons: 1, detail: 2,
      bubbles: true, cancelable: true,
    }));
    _dragActive = true;
  }

  /** Dispatch synthetic mousemove to extend selection during drag. */
  function _extendDragSelect(clientX: number, clientY: number): void {
    if (!_dragActive) return;
    // Hide chip during drag — user is actively selecting
    _hideChip();
    document.dispatchEvent(new MouseEvent('mousemove', {
      clientX, clientY,
      button: 0, buttons: 1,
      bubbles: true, cancelable: true,
    }));
  }

  /** Dispatch synthetic mouseup to finalize selection. */
  function _endDragSelect(): void {
    if (!_dragActive) return;
    _dragActive = false;
    document.dispatchEvent(new MouseEvent('mouseup', {
      button: 0,
      bubbles: true, cancelable: true,
    }));
    // Copy button visibility is handled by _watchSelection via onSelectionChange
  }
}

// ── Selection watcher ────────────────────────────────────────────────────────

function _watchSelection(copyBtn: HTMLElement): void {
  if (!appState.terminal) return;
  appState.terminal.onSelectionChange(() => {
    const sel = appState.terminal?.getSelection();
    if (sel) {
      _selectionActive = true;
      copyBtn.classList.remove('hidden');
    } else {
      copyBtn.classList.add('hidden');
      // Don't clear _selectionActive here — the chip might still be showing
    }
  });
}
