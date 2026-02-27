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
import { toast, focusIME, setCtrlActive, toggleComposeMode } from './ui.js';
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
            if (appState.imeMode)
                toggleComposeMode();
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
            if (appState.imeMode)
                toggleComposeMode();
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
            console.log('[scroll] flush scrollLines=', _pendingLines);
            appState.terminal.scrollLines(_pendingLines);
            _pendingLines = 0;
        }
        if (_pendingSGR && _pendingSGR.count > 0) {
            const { btn, col, row, count } = _pendingSGR;
            console.log('[scroll] flush SGR btn=', btn, 'count=', count, 'col=', col, 'row=', row);
            for (let i = 0; i < count; i++)
                sendSSHInput(`\x1b[<${String(btn)};${String(col)};${String(row)}M`);
            _pendingSGR = null;
        }
    }
    function _scheduleScrollFlush() {
        if (!_scrollRafId)
            _scrollRafId = requestAnimationFrame(_flushScroll);
    }
    // nosemgrep: duplicate-event-listener -- scroll (1-finger) and pinch (2-finger) are separate gestures
    termEl.addEventListener('touchstart', (e) => {
        console.log('[scroll] touchstart y=', e.touches[0].clientY, 'touches=', e.touches.length);
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
    }, { passive: true, capture: true });
    // nosemgrep: duplicate-event-listener
    termEl.addEventListener('touchmove', (e) => {
        if (_touchStartY === null || _touchStartX === null)
            return;
        const totalDy = _touchStartY - e.touches[0].clientY;
        const totalDx = _touchStartX - e.touches[0].clientX;
        if (!_isTouchScroll && Math.abs(totalDy) > 12 && Math.abs(totalDy) > Math.abs(totalDx)) {
            _isTouchScroll = true;
            console.log('[scroll] gesture claimed, totalDy=', totalDy);
        }
        // Once we've claimed this gesture as a terminal scroll, prevent the
        // browser's native scroll/bounce so it doesn't fight our handler.
        if (_isTouchScroll)
            e.preventDefault();
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
                console.log('[scroll] delta=', delta, 'mouseMode=', mouseMode);
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
                    console.log('[scroll] SGR queued btn=', btn, 'count=', count);
                }
                else {
                    _pendingLines += delta;
                    console.log('[scroll] scrollLines queued=', _pendingLines);
                }
                _scheduleScrollFlush();
            }
        }
        _lastTouchY = e.touches[0].clientY;
        _lastTouchX = e.touches[0].clientX;
    }, { passive: false, capture: true });
    // nosemgrep: duplicate-event-listener
    termEl.addEventListener('touchend', () => {
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
        if (!wasScroll) {
            if (Math.abs(finalDx) > 40 && Math.abs(finalDx) > Math.abs(finalDy)) {
                sendSSHInput(finalDx < 0 ? '\x02p' : '\x02n');
            }
            else {
                setTimeout(focusIME, 50);
            }
        }
    }, { capture: true });
    // ── Pinch-to-zoom → font size (#17) — behind enablePinchZoom setting ────
    let _pinchStartDist = null;
    let _pinchStartSize = null;
    function _pinchEnabled() {
        return localStorage.getItem('enablePinchZoom') === 'true';
    }
    function _pinchDist(touches) {
        const dx = touches[0].clientX - touches[1].clientX;
        const dy = touches[0].clientY - touches[1].clientY;
        return Math.sqrt(dx * dx + dy * dy);
    }
    termEl.addEventListener('touchstart', (e) => {
        if (e.touches.length !== 2 || !_pinchEnabled())
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