/**
 * modules/ime.ts — IME input layer
 *
 * Handles all keyboard/IME input routing from hidden textarea (#imeInput)
 * and direct-mode password input (#directInput) to the SSH stream.
 *
 * Also manages: selection overlay for mobile copy (#55), touch/swipe
 * gesture handlers (#32/#37/#16), and pinch-to-zoom (#17).
 */
import { KEY_MAP } from './constants.js';
import { appState } from './state.js';
import { sendSSHInput } from './connection.js';
import { toast, focusIME, setCtrlActive } from './ui.js';
let _handleResize = () => { };
let _applyFontSize = (_size) => { };
export function initIME({ handleResize, applyFontSize }) {
    _handleResize = handleResize;
    _applyFontSize = applyFontSize;
}
export function initIMEInput() {
    const ime = document.getElementById('imeInput');
    // ── IME composition preview helper (#44) ──────────────────────────────
    function _imePreviewShow(text) {
        const el = document.getElementById('imePreview');
        if (!el)
            return;
        if (text) {
            el.textContent = text;
            el.classList.remove('hidden');
        }
        else {
            el.classList.add('hidden');
        }
    }
    // ── input event ─────────────────────────────────────────────────────────
    ime.addEventListener('input', () => {
        if (appState.isComposing) {
            _imePreviewShow(ime.value || null);
            return;
        }
        const text = ime.value;
        ime.value = '';
        if (!text)
            return;
        if (text === '\n') {
            sendSSHInput('\r');
            return;
        }
        if (appState.ctrlActive) {
            const code = text[0].toLowerCase().charCodeAt(0) - 96;
            sendSSHInput(code >= 1 && code <= 26 ? String.fromCharCode(code) : text);
            setCtrlActive(false);
        }
        else {
            sendSSHInput(text);
        }
    });
    // ── IME composition (multi-step input methods, e.g. CJK, Gboard swipe) ─
    ime.addEventListener('compositionstart', () => {
        appState.isComposing = true;
    });
    ime.addEventListener('compositionupdate', (e) => {
        if (e.data)
            _imePreviewShow(e.data);
    });
    ime.addEventListener('compositionend', (e) => {
        appState.isComposing = false;
        _imePreviewShow(null);
        const text = ime.value || e.data;
        ime.value = '';
        if (!text)
            return;
        if (text === '\n') {
            sendSSHInput('\r');
            return;
        }
        if (appState.ctrlActive) {
            const code = text[0].toLowerCase().charCodeAt(0) - 96;
            sendSSHInput(code >= 1 && code <= 26 ? String.fromCharCode(code) : text);
            setCtrlActive(false);
        }
        else {
            sendSSHInput(text);
        }
    });
    ime.addEventListener('compositioncancel', () => {
        appState.isComposing = false;
        _imePreviewShow(null);
        ime.value = '';
    });
    // ── keydown: special keys not captured by 'input' ─────────────────────
    ime.addEventListener('keydown', (e) => {
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
            }
            else {
                sendSSHInput(e.key);
            }
            e.preventDefault();
            ime.value = '';
        }
    });
    // termEl used by selection overlay, gesture handlers, and pinch-to-zoom
    const termEl = document.getElementById('terminal');
    // ── Selection overlay for mobile copy (#55) ──────────────────────────
    const selOverlay = document.getElementById('selectionOverlay');
    const selBar = document.getElementById('selectionBar');
    let _overlayCellH = 0;
    const URL_RE = /https?:\/\/[^\s<>"')\]]+/g;
    function _stripTrailingPunct(url) {
        return url.replace(/[.,;:!?)]+$/, '');
    }
    appState._syncOverlayMetrics = function _syncOverlayMetricsFn() {
        if (!appState.terminal || !selOverlay)
            return;
        const screen = document.querySelector('.xterm-screen');
        if (!screen)
            return;
        const cellH = screen.offsetHeight / appState.terminal.rows;
        const cellW = screen.offsetWidth / appState.terminal.cols;
        _overlayCellH = cellH;
        selOverlay.style.fontFamily = appState.terminal.options.fontFamily ?? '';
        selOverlay.style.fontSize = `${String(appState.terminal.options.fontSize ?? 14)}px`;
        selOverlay.style.lineHeight = `${String(cellH)}px`;
        const screenRect = screen.getBoundingClientRect();
        const termRect = termEl.getBoundingClientRect();
        selOverlay.style.top = `${String(screenRect.top - termRect.top)}px`;
        selOverlay.style.left = `${String(screenRect.left - termRect.left)}px`;
        selOverlay.style.width = `${String(screenRect.width)}px`;
        selOverlay.style.height = `${String(screenRect.height)}px`;
        const testSpan = document.createElement('span');
        testSpan.style.font = `${String(appState.terminal.options.fontSize ?? 14)}px ${appState.terminal.options.fontFamily ?? ''}`;
        testSpan.style.visibility = 'hidden';
        testSpan.style.position = 'absolute';
        testSpan.textContent = 'M';
        document.body.appendChild(testSpan);
        const charW = testSpan.getBoundingClientRect().width;
        document.body.removeChild(testSpan);
        const spacing = cellW - charW;
        selOverlay.style.letterSpacing = `${String(spacing)}px`;
    };
    function syncSelectionOverlay() {
        if (!appState.terminal || !selOverlay)
            return;
        appState._syncOverlayMetrics?.();
        const buf = appState.terminal.buffer.active;
        const startLine = buf.viewportY;
        const frag = document.createDocumentFragment();
        for (let i = 0; i < appState.terminal.rows; i++) {
            const line = buf.getLine(startLine + i);
            const text = line ? line.translateToString(true) : '';
            const div = document.createElement('div');
            div.className = 'sel-line';
            if (_overlayCellH)
                div.style.height = `${String(_overlayCellH)}px`;
            let lastIdx = 0;
            URL_RE.lastIndex = 0;
            let hasUrl = false;
            let match;
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
        if (!selOverlay?.firstChild)
            return;
        const range = document.createRange();
        range.selectNodeContents(selOverlay);
        const sel = window.getSelection();
        if (!sel)
            return;
        sel.removeAllRanges();
        sel.addRange(range);
    }
    function enterSelectionMode(x, y) {
        if (appState._selectionActive)
            return;
        appState._selectionActive = true;
        syncSelectionOverlay();
        selOverlay?.classList.add('active');
        let selected = false;
        if ('caretRangeFromPoint' in document) {
            // eslint-disable-next-line @typescript-eslint/no-deprecated -- fallback for older browsers
            const range = document.caretRangeFromPoint(x, y);
            if (range?.startContainer.nodeType === Node.TEXT_NODE) {
                _expandToWord(range);
                const wordText = range.toString().trim();
                if (wordText.length > 0) {
                    const sel = window.getSelection();
                    if (sel) {
                        sel.removeAllRanges();
                        sel.addRange(range);
                        selected = true;
                    }
                }
            }
        }
        if (!selected)
            _selectAllOverlay();
        selBar?.classList.remove('hidden');
        _updateSelBar();
    }
    function exitSelectionMode() {
        appState._selectionActive = false;
        selOverlay?.classList.remove('active');
        if (selOverlay)
            selOverlay.innerHTML = '';
        selBar?.classList.add('hidden');
        window.getSelection()?.removeAllRanges();
        focusIME();
        setTimeout(_handleResize, 200);
    }
    function _expandToWord(range) {
        const node = range.startContainer;
        const text = node.textContent ?? '';
        let start = range.startOffset;
        let end = start;
        while (start > 0 && !/\s/.test(text[start - 1] ?? ''))
            start--;
        while (end < text.length && !/\s/.test(text[end] ?? ''))
            end++;
        range.setStart(node, start);
        range.setEnd(node, end);
    }
    function _updateSelBar() {
        const sel = window.getSelection();
        if (!sel)
            return;
        const text = sel.toString();
        const openBtn = document.getElementById('selOpenBtn');
        let url = null;
        if (sel.anchorNode) {
            const urlEl = sel.anchorNode.parentElement?.closest('.sel-url');
            if (urlEl)
                url = urlEl.dataset.url ?? null;
        }
        if (!url) {
            const m = text.match(/https?:\/\/[^\s]+/);
            if (m?.[0])
                url = _stripTrailingPunct(m[0]);
        }
        if (url && openBtn) {
            openBtn.classList.remove('hidden');
            openBtn.dataset.url = url;
        }
        else if (openBtn) {
            openBtn.classList.add('hidden');
        }
    }
    // Copy bar button handlers
    document.getElementById('selAllBtn')?.addEventListener('click', (e) => {
        e.stopPropagation();
        _selectAllOverlay();
        _updateSelBar();
    });
    document.getElementById('selCopyBtn')?.addEventListener('click', (e) => {
        e.stopPropagation();
        const text = window.getSelection()?.toString();
        if (text) {
            void navigator.clipboard.writeText(text).then(() => { toast('Copied'); }).catch(() => { toast('Copy failed'); });
        }
        exitSelectionMode();
    });
    document.getElementById('selOpenBtn')?.addEventListener('click', (e) => {
        e.stopPropagation();
        const url = e.currentTarget.dataset.url;
        if (url)
            window.open(url, '_blank', 'noopener');
        exitSelectionMode();
    });
    document.getElementById('selDoneBtn')?.addEventListener('click', (e) => {
        e.stopPropagation();
        exitSelectionMode();
    });
    document.addEventListener('selectionchange', () => {
        if (!appState._selectionActive)
            return;
        _updateSelBar();
        const sel = window.getSelection();
        if (!sel?.toString()) {
            setTimeout(() => {
                if (appState._selectionActive && !window.getSelection()?.toString()) {
                    exitSelectionMode();
                }
            }, 300);
        }
    });
    selOverlay?.addEventListener('click', (e) => {
        if (!appState._selectionActive)
            return;
        const urlEl = e.target.closest('.sel-url');
        if (urlEl) {
            const range = document.createRange();
            range.selectNodeContents(urlEl);
            const sel = window.getSelection();
            if (sel) {
                sel.removeAllRanges();
                sel.addRange(range);
            }
            _updateSelBar();
            e.preventDefault();
        }
    });
    // SELECTION_OVERLAY is off — contextmenu prevention disabled
    // Long-press detection — 500ms hold without movement activates selection mode
    let _longPressTimer = null;
    const _longPressX = 0;
    const _longPressY = 0;
    const LONG_PRESS_MS = 500;
    const LONG_PRESS_MOVE_THRESHOLD = 8;
    function _cancelLongPress() {
        if (_longPressTimer) {
            clearTimeout(_longPressTimer);
            _longPressTimer = null;
        }
    }
    // ── Tap + swipe gestures on terminal (#32/#37/#16) ────────────────────
    termEl.addEventListener('click', focusIME);
    let _touchStartY = null;
    let _touchStartX = null;
    let _lastTouchY = null;
    let _lastTouchX = null;
    let _isTouchScroll = false;
    let _scrolledLines = 0;
    let _pendingLines = 0;
    let _pendingSGR = null;
    let _scrollRafId = null;
    function _flushScroll() {
        _scrollRafId = null;
        if (_pendingLines !== 0 && appState.terminal) {
            appState.terminal.scrollLines(_pendingLines);
            _pendingLines = 0;
        }
        if (_pendingSGR && _pendingSGR.count > 0) {
            const { btn, col, row, count } = _pendingSGR;
            for (let i = 0; i < count; i++)
                sendSSHInput(`\x1b[<${String(btn)};${String(col)};${String(row)}M`);
            _pendingSGR = null;
        }
    }
    function _scheduleScrollFlush() {
        if (!_scrollRafId)
            _scrollRafId = requestAnimationFrame(_flushScroll);
    }
    termEl.addEventListener('touchstart', (e) => {
        _touchStartY = _lastTouchY = e.touches[0].clientY;
        _touchStartX = _lastTouchX = e.touches[0].clientX;
        _isTouchScroll = false;
        _scrolledLines = 0;
        _pendingLines = 0;
        _pendingSGR = null;
        if (_scrollRafId) {
            cancelAnimationFrame(_scrollRafId);
            _scrollRafId = null;
        }
        // SELECTION_OVERLAY is off — long-press detection disabled
    }, { passive: true, capture: true });
    termEl.addEventListener('touchmove', (e) => {
        if (_touchStartY === null || _touchStartX === null)
            return;
        const totalDy = _touchStartY - e.touches[0].clientY;
        const totalDx = _touchStartX - e.touches[0].clientX;
        if (_longPressTimer) {
            const dx = e.touches[0].clientX - _longPressX;
            const dy = e.touches[0].clientY - _longPressY;
            if (Math.sqrt(dx * dx + dy * dy) > LONG_PRESS_MOVE_THRESHOLD)
                _cancelLongPress();
        }
        if (!_isTouchScroll && Math.abs(totalDy) > 12 && Math.abs(totalDy) > Math.abs(totalDx)) {
            _isTouchScroll = true;
        }
        if (_isTouchScroll && appState.terminal) {
            const cellH = Math.max(20, (appState.terminal.options.fontSize ?? 14) * 1.5);
            const targetLines = Math.round(totalDy / cellH);
            const delta = targetLines - _scrolledLines;
            if (delta !== 0) {
                _scrolledLines = targetLines;
                // eslint-disable-next-line @typescript-eslint/no-unsafe-member-access -- xterm modes is untyped
                const termUnk = appState.terminal;
                const mouseMode = termUnk.modes &&
                    termUnk.modes.mouseTrackingMode;
                if (mouseMode && mouseMode !== 'none') {
                    const btn = delta > 0 ? 65 : 64;
                    const rect = termEl.getBoundingClientRect();
                    const col = Math.max(1, Math.min(appState.terminal.cols, Math.floor((e.touches[0].clientX - rect.left) / (rect.width / appState.terminal.cols)) + 1));
                    const row = Math.max(1, Math.min(appState.terminal.rows, Math.floor((e.touches[0].clientY - rect.top) / (rect.height / appState.terminal.rows)) + 1));
                    const count = Math.abs(delta);
                    if (_pendingSGR?.btn === btn) {
                        _pendingSGR.count += count;
                    }
                    else {
                        _pendingSGR = { btn, col, row, count };
                    }
                }
                else {
                    _pendingLines += delta;
                }
                _scheduleScrollFlush();
            }
        }
        _lastTouchY = e.touches[0].clientY;
        _lastTouchX = e.touches[0].clientX;
    }, { passive: true, capture: true });
    termEl.addEventListener('touchend', () => {
        _cancelLongPress();
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
        if (_scrollRafId) {
            cancelAnimationFrame(_scrollRafId);
            _scrollRafId = null;
        }
        if (!wasScroll && !appState._selectionActive) {
            if (Math.abs(finalDx) > 40 && Math.abs(finalDx) > Math.abs(finalDy)) {
                sendSSHInput(finalDx < 0 ? '\x02p' : '\x02n');
            }
            else {
                setTimeout(focusIME, 50);
            }
        }
    }, { capture: true });
    // end swipe gestures
    // ── Pinch-to-zoom → font size (#17) ──────────────────────────────────────
    let _pinchStartDist = null;
    let _pinchStartSize = null;
    function _pinchDist(touches) {
        const dx = touches[0].clientX - touches[1].clientX;
        const dy = touches[0].clientY - touches[1].clientY;
        return Math.sqrt(dx * dx + dy * dy);
    }
    termEl.addEventListener('touchstart', (e) => {
        if (e.touches.length !== 2)
            return;
        _pinchStartDist = _pinchDist(e.touches);
        _pinchStartSize = appState.terminal
            ? (appState.terminal.options.fontSize ?? 14)
            : (parseInt(localStorage.getItem('fontSize') ?? '14') || 14);
        e.preventDefault();
    }, { passive: false });
    termEl.addEventListener('touchmove', (e) => {
        if (e.touches.length !== 2 || _pinchStartDist === null || _pinchStartSize === null)
            return;
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
    // ── Direct input (type="password") — char-by-char mode (#44/#48) ─────
    const directEl = document.getElementById('directInput');
    directEl.addEventListener('input', () => {
        const text = directEl.value;
        directEl.value = '';
        if (!text)
            return;
        if (text === '\n') {
            sendSSHInput('\r');
            return;
        }
        if (appState.ctrlActive) {
            const code = text[0].toLowerCase().charCodeAt(0) - 96;
            sendSSHInput(code >= 1 && code <= 26 ? String.fromCharCode(code) : text);
            setCtrlActive(false);
        }
        else {
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
        const mapped = KEY_MAP[e.key];
        if (mapped) {
            sendSSHInput(mapped);
            e.preventDefault();
            return;
        }
        if (e.key.length === 1 && !e.ctrlKey && !e.altKey && !e.metaKey) {
            if (appState.ctrlActive) {
                const code = e.key.toLowerCase().charCodeAt(0) - 96;
                sendSSHInput(code >= 1 && code <= 26 ? String.fromCharCode(code) : e.key);
                setCtrlActive(false);
            }
            else {
                sendSSHInput(e.key);
            }
            e.preventDefault();
            directEl.value = '';
        }
    });
}
//# sourceMappingURL=ime.js.map