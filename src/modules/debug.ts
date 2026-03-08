/**
 * modules/debug.ts — On-screen debug overlay for mobile
 *
 * Captures console.log/warn/error output and displays
 * it in a floating panel. Controlled by the "Debug overlay" toggle in settings.
 */

const MAX_LINES = 200;
let _lines: string[] = [];
let _enabled = false;
let _panel: HTMLElement | null = null;
let _log: HTMLElement | null = null;
const _origLog = console.log;
const _origWarn = console.warn;
const _origError = console.error;

export function isDebugEnabled(): boolean {
  return _enabled;
}

function _appendLine(level: string, args: unknown[]): void {
  const text = args.map(a =>
    typeof a === 'string' ? a : JSON.stringify(a)
  ).join(' ');
  const ts = new Date().toLocaleTimeString('en', { hour12: false, fractionalSecondDigits: 1 } as Intl.DateTimeFormatOptions);
  const line = `${ts} ${level} ${text}`;
  _lines.push(line);
  if (_lines.length > MAX_LINES) _lines = _lines.slice(-MAX_LINES);

  if (_log) {
    const div = document.createElement('div');
    div.textContent = line;
    if (level === 'W') div.style.color = '#ffaa00';
    if (level === 'E') div.style.color = '#ff4444';
    _log.appendChild(div);
    if (_log.children.length > MAX_LINES) {
      _log.removeChild(_log.children[0]!);
    }
    _log.scrollTop = _log.scrollHeight;
  }
}

const _suppressTags = ['[scroll]'];

function _isSuppressed(args: unknown[]): boolean {
  if (args.length === 0) return false;
  const first = args[0];
  if (typeof first !== 'string') return false;
  return _suppressTags.some(tag => first.startsWith(tag));
}

function _hookConsole(): void {
  console.log = (...args: unknown[]) => {
    _origLog.apply(console, args);
    if (_enabled && !_isSuppressed(args)) _appendLine('I', args);
  };
  console.warn = (...args: unknown[]) => {
    _origWarn.apply(console, args);
    if (_enabled && !_isSuppressed(args)) _appendLine('W', args);
  };
  console.error = (...args: unknown[]) => {
    _origError.apply(console, args);
    if (_enabled) _appendLine('E', args);
  };
}

export function initDebugOverlay(): void {
  _panel = document.getElementById('debugOverlayPanel');
  _log = document.getElementById('debugOverlayLog');

  const toggle = document.getElementById('debugOverlay') as HTMLInputElement | null;
  if (toggle) {
    _enabled = localStorage.getItem('debugOverlay') === 'true';
    toggle.checked = _enabled;
    if (_enabled && _panel) _panel.classList.remove('hidden');

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
    void navigator.clipboard.writeText(text).then(
      () => { _origLog('[debug] Copied', _lines.length, 'lines'); },
      () => { _origLog('[debug] Clipboard write failed'); }
    );
  });

  document.getElementById('debugClearBtn')?.addEventListener('click', () => {
    _lines = [];
    if (_log) _log.innerHTML = '';
  });

  _hookConsole();
}
