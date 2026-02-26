/**
 * modules/terminal.ts — Terminal init, resize, keyboard awareness, font & theme
 */
import { THEMES, ANSI, FONT_SIZE } from './constants.js';
import { appState } from './state.js';
// ── CSS layout constants (read from :root once; JS never hardcodes px values) ─
export const ROOT_CSS = (() => {
    const s = getComputedStyle(document.documentElement);
    return {
        tabHeight: s.getPropertyValue('--tab-height').trim(),
        keybarHeight: s.getPropertyValue('--keybar-height').trim(),
    };
})();
// ── Terminal ─────────────────────────────────────────────────────────────────
const FONT_FAMILIES = {
    monospace: 'ui-monospace, Menlo, "Cascadia Code", Consolas, monospace',
    jetbrains: '"JetBrains Mono", monospace',
    firacode: '"Fira Code", monospace',
};
export function initTerminal() {
    const fontSize = parseInt(localStorage.getItem('fontSize') ?? '14') || 14;
    const savedTheme = localStorage.getItem('termTheme') ?? 'dark';
    appState.activeThemeName = (savedTheme in THEMES ? savedTheme : 'dark');
    const savedFont = localStorage.getItem('termFont') ?? 'monospace';
    const fontFamily = FONT_FAMILIES[savedFont] ?? FONT_FAMILIES.monospace;
    appState.terminal = new Terminal({
        fontFamily,
        fontSize,
        theme: THEMES[appState.activeThemeName].theme,
        cursorBlink: true,
        scrollback: 5000,
        convertEol: false,
    });
    appState.fitAddon = new FitAddon.FitAddon();
    appState.terminal.loadAddon(appState.fitAddon);
    appState.terminal.open(document.getElementById('terminal'));
    appState.fitAddon.fit();
    // Re-measure character cells after web fonts finish loading (#71)
    void document.fonts.ready.then(() => {
        if (!appState.terminal || !fontFamily)
            return;
        appState.terminal.options.fontFamily = fontFamily;
        appState.fitAddon?.fit();
    });
    window.addEventListener('resize', handleResize);
    // Show welcome banner
    appState.terminal.writeln(ANSI.bold(ANSI.green('MobiSSH')));
    appState.terminal.writeln(ANSI.dim('Tap terminal to activate keyboard  •  Use Connect tab to open a session'));
    appState.terminal.writeln('');
}
export function handleResize() {
    appState.fitAddon?.fit();
    if (appState.sshConnected && appState.ws?.readyState === WebSocket.OPEN) {
        appState.ws.send(JSON.stringify({
            type: 'resize',
            cols: appState.terminal?.cols ?? 80,
            rows: appState.terminal?.rows ?? 24,
        }));
    }
}
// ── Keyboard visibility awareness ───────────────────────────────────────────
let keyboardVisible = false;
export function getKeyboardVisible() {
    return keyboardVisible;
}
export function initKeyboardAwareness() {
    if (!window.visualViewport)
        return;
    const app = document.getElementById('app');
    if (!app)
        return;
    function onViewportChange() {
        const vv = window.visualViewport;
        if (!vv)
            return;
        const h = Math.round(vv.height);
        keyboardVisible = h < window.outerHeight * 0.75;
        app.style.height = `${String(h)}px`;
        appState.fitAddon?.fit();
        appState.terminal?.scrollToBottom();
        if (appState.sshConnected && appState.ws?.readyState === WebSocket.OPEN) {
            appState.ws.send(JSON.stringify({ type: 'resize', cols: appState.terminal?.cols ?? 80, rows: appState.terminal?.rows ?? 24 }));
        }
    }
    window.visualViewport.addEventListener('resize', onViewportChange);
}
// ── Font size & theme ────────────────────────────────────────────────────────
export function applyFontSize(size) {
    size = Math.max(FONT_SIZE.MIN, Math.min(FONT_SIZE.MAX, size));
    localStorage.setItem('fontSize', String(size));
    const rangeEl = document.getElementById('fontSize');
    const labelEl = document.getElementById('fontSizeValue');
    const menuLabel = document.getElementById('fontSizeLabel');
    if (rangeEl)
        rangeEl.value = String(size);
    if (labelEl)
        labelEl.textContent = `${String(size)}px`;
    if (menuLabel)
        menuLabel.textContent = `${String(size)}px`;
    if (appState.terminal) {
        appState.terminal.options.fontSize = size;
        appState.fitAddon?.fit();
        if (appState.sshConnected && appState.ws?.readyState === WebSocket.OPEN) {
            appState.ws.send(JSON.stringify({ type: 'resize', cols: appState.terminal.cols, rows: appState.terminal.rows }));
        }
    }
}
export function applyTheme(name, { persist = false } = {}) {
    if (!(name in THEMES))
        return;
    const t = THEMES[name];
    appState.activeThemeName = name;
    if (appState.terminal)
        appState.terminal.options.theme = t.theme;
    if (persist)
        localStorage.setItem('termTheme', name);
    const menuBtn = document.getElementById('sessionThemeBtn');
    if (menuBtn)
        menuBtn.textContent = `Theme: ${t.label} ▸`;
    const sel = document.getElementById('termThemeSelect');
    if (sel)
        sel.value = name;
}
//# sourceMappingURL=terminal.js.map