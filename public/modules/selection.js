/**
 * modules/selection.ts — Mobile text selection (#55)
 *
 * Long-press on the terminal surface shows an action chip with selection
 * options (Paste, Select Visible, Select All). When xterm.js has an active
 * selection, a Copy button appears on the session handle bar.
 *
 * Uses xterm.js's built-in selection system — selection is rendered on the
 * canvas using the theme's selectionBackground. No DOM overlay.
 */
import { appState } from './state.js';
import { sendSSHInput } from './connection.js';
import { toast, focusIME } from './ui.js';
// ── State ────────────────────────────────────────────────────────────────────
let _selectionActive = false;
let _longPressTimer = null;
let _touchAnchorX = 0;
let _touchAnchorY = 0;
const LONG_PRESS_MS = 500;
const LONG_PRESS_MOVE_THRESHOLD = 10; // px
// ── Public API ───────────────────────────────────────────────────────────────
/** True while the selection action chip is visible or a selection exists. */
export function isSelectionActive() {
    return _selectionActive;
}
/** Call once after terminal is created and DOM is ready. */
export function initSelection() {
    const termEl = document.getElementById('terminal');
    const chip = document.getElementById('selectionChip');
    const copyBtn = document.getElementById('handleCopyBtn');
    // ── Long-press detection ─────────────────────────────────────────────────
    termEl.addEventListener('touchstart', (e) => {
        if (e.touches.length !== 1)
            return;
        _touchAnchorX = e.touches[0].clientX;
        _touchAnchorY = e.touches[0].clientY;
        _longPressTimer = setTimeout(() => {
            _longPressTimer = null;
            _onLongPress();
        }, LONG_PRESS_MS);
    }, { passive: true });
    termEl.addEventListener('touchmove', (e) => {
        if (_longPressTimer === null)
            return;
        const dx = e.touches[0].clientX - _touchAnchorX;
        const dy = e.touches[0].clientY - _touchAnchorY;
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
    }, { passive: true });
    // Dismiss chip on tap outside it (but inside terminal)
    termEl.addEventListener('click', (e) => {
        if (_selectionActive && !e.target.closest('#selectionChip')) {
            _dismissSelection();
        }
    });
    // ── Action chip buttons ──────────────────────────────────────────────────
    document.getElementById('selectionPasteBtn').addEventListener('click', (e) => {
        e.stopPropagation();
        void navigator.clipboard.readText().then((text) => {
            if (text)
                sendSSHInput(text);
            else
                toast('Clipboard empty');
        }).catch(() => { toast('Paste failed'); });
        _hideChip();
    });
    document.getElementById('selectionVisibleBtn').addEventListener('click', (e) => {
        e.stopPropagation();
        if (!appState.terminal)
            return;
        const buf = appState.terminal.buffer.active;
        appState.terminal.selectLines(buf.viewportY, buf.viewportY + appState.terminal.rows - 1);
        _hideChip();
    });
    document.getElementById('selectionAllBtn').addEventListener('click', (e) => {
        e.stopPropagation();
        if (!appState.terminal)
            return;
        appState.terminal.selectAll();
        _hideChip();
    });
    document.getElementById('selectionDismissBtn').addEventListener('click', (e) => {
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
    function _onLongPress() {
        _selectionActive = true;
        try {
            navigator.vibrate(30);
        }
        catch { /* vibrate not available */ }
        // Blur IME to dismiss soft keyboard before showing chip
        document.activeElement?.blur();
        chip.classList.remove('hidden');
        // Push history entry so Android back gesture dismisses the chip
        history.pushState({ selectionChip: true }, '');
    }
    function _hideChip() {
        chip.classList.add('hidden');
    }
    function _dismissSelection() {
        if (!_selectionActive)
            return;
        _selectionActive = false;
        _hideChip();
        appState.terminal?.clearSelection();
        copyBtn.classList.add('hidden');
        // Pop the history entry we pushed (unless back gesture already did it)
        if (history.state?.selectionChip === true) {
            history.back();
        }
        setTimeout(focusIME, 50);
    }
}
// ── Selection watcher ────────────────────────────────────────────────────────
function _watchSelection(copyBtn) {
    if (!appState.terminal)
        return;
    appState.terminal.onSelectionChange(() => {
        const sel = appState.terminal?.getSelection();
        if (sel) {
            _selectionActive = true;
            copyBtn.classList.remove('hidden');
        }
        else {
            copyBtn.classList.add('hidden');
            // Don't clear _selectionActive here — the chip might still be showing
        }
    });
}
//# sourceMappingURL=selection.js.map