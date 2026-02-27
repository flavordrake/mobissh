/**
 * modules/debug.ts — On-screen debug overlay for mobile
 *
 * Captures console.log/warn/error output tagged with [scroll] and displays
 * it in a floating panel. Controlled by the "Debug overlay" toggle in settings.
 */
const MAX_LINES = 200;
let _lines = [];
let _enabled = false;
let _panel = null;
let _log = null;
const _origLog = console.log;
const _origWarn = console.warn;
export function isDebugEnabled() {
    return _enabled;
}
function _appendLine(level, args) {
    const text = args.map(a => typeof a === 'string' ? a : JSON.stringify(a)).join(' ');
    const ts = new Date().toLocaleTimeString('en', { hour12: false, fractionalSecondDigits: 1 });
    const line = `${ts} ${level} ${text}`;
    _lines.push(line);
    if (_lines.length > MAX_LINES)
        _lines = _lines.slice(-MAX_LINES);
    if (_log) {
        const div = document.createElement('div');
        div.textContent = line;
        if (level === 'W')
            div.style.color = '#ffaa00';
        _log.appendChild(div);
        if (_log.children.length > MAX_LINES) {
            _log.removeChild(_log.children[0]);
        }
        _log.scrollTop = _log.scrollHeight;
    }
}
function _hookConsole() {
    console.log = (...args) => {
        _origLog.apply(console, args);
        if (_enabled)
            _appendLine('I', args);
    };
    console.warn = (...args) => {
        _origWarn.apply(console, args);
        if (_enabled)
            _appendLine('W', args);
    };
}
export function initDebugOverlay() {
    _panel = document.getElementById('debugOverlayPanel');
    _log = document.getElementById('debugOverlayLog');
    const toggle = document.getElementById('debugOverlay');
    if (toggle) {
        _enabled = localStorage.getItem('debugOverlay') === 'true';
        toggle.checked = _enabled;
        if (_enabled && _panel)
            _panel.classList.remove('hidden');
        toggle.addEventListener('change', () => {
            _enabled = toggle.checked;
            localStorage.setItem('debugOverlay', _enabled ? 'true' : 'false');
            if (_panel) {
                _panel.classList.toggle('hidden', !_enabled);
            }
        });
    }
    document.getElementById('debugCopyBtn')?.addEventListener('click', () => {
        const text = _lines.join('\n');
        void navigator.clipboard.writeText(text).then(() => { _origLog('[debug] Copied', _lines.length, 'lines'); }, () => { _origLog('[debug] Clipboard write failed'); });
    });
    document.getElementById('debugClearBtn')?.addEventListener('click', () => {
        _lines = [];
        if (_log)
            _log.innerHTML = '';
    });
    _hookConsole();
}
//# sourceMappingURL=debug.js.map