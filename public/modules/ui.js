/**
 * modules/ui.ts — UI chrome
 *
 * Session menu, tab bar, key bar, connect form, status indicator,
 * toast utility, IME focus, and Ctrl modifier management.
 */
import { KEY_REPEAT, THEMES, THEME_ORDER } from './constants.js';
import { appState } from './state.js';
import { sendSSHInput, disconnect, reconnect, connect } from './connection.js';
import { startRecording, stopAndDownloadRecording } from './recording.js';
import { saveProfile, getKeys } from './profiles.js';
let _keyboardVisible = () => false;
let _ROOT_CSS = { tabHeight: '56px', keybarHeight: '34px' };
let _applyFontSize = (_size) => { };
let _applyTheme = (_name, _opts) => { };
export function initUI({ keyboardVisible, ROOT_CSS, applyFontSize, applyTheme }) {
    _keyboardVisible = keyboardVisible;
    _ROOT_CSS = ROOT_CSS;
    _applyFontSize = applyFontSize;
    _applyTheme = applyTheme;
}
// ── Toast ────────────────────────────────────────────────────────────────────
let toastTimer = null;
export function toast(msg) {
    let el = document.getElementById('toast');
    if (!el) {
        el = document.createElement('div');
        el.id = 'toast';
        document.body.appendChild(el);
    }
    el.textContent = msg;
    el.classList.add('show');
    if (toastTimer)
        clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { el.classList.remove('show'); }, 2500);
}
// ── Status indicator ─────────────────────────────────────────────────────────
export function setStatus(state, text) {
    const btn = document.getElementById('sessionMenuBtn');
    if (btn) {
        btn.textContent = state === 'connected' ? text : 'MobiSSH';
        btn.classList.toggle('connected', state === 'connected');
    }
}
// ── Focus IME ────────────────────────────────────────────────────────────────
export function focusIME() {
    const id = appState.imeMode ? 'imeInput' : 'directInput';
    document.getElementById(id)?.focus({ preventScroll: true });
}
// ── Session menu (#39) ───────────────────────────────────────────────────────
export function initSessionMenu() {
    const menuBtn = document.getElementById('sessionMenuBtn');
    const menu = document.getElementById('sessionMenu');
    const backdrop = document.getElementById('menuBackdrop');
    // Sync session menu theme label with the active theme
    const initialTheme = THEMES[appState.activeThemeName];
    const themeBtn = document.getElementById('sessionThemeBtn');
    if (themeBtn)
        themeBtn.textContent = `Theme: ${initialTheme.label} ▸`;
    // Prevent focus theft only when the keyboard is already visible (#51).
    menuBtn.addEventListener('mousedown', (e) => {
        if (_keyboardVisible())
            e.preventDefault();
    });
    menuBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        if (!appState.sshConnected)
            return;
        const wasHidden = menu.classList.toggle('hidden');
        backdrop.classList.toggle('hidden', wasHidden);
    });
    function closeMenu() { menu.classList.add('hidden'); backdrop.classList.add('hidden'); }
    backdrop.addEventListener('click', closeMenu);
    // Font size +/− — menu stays open so user can tap repeatedly (#46)
    document.getElementById('fontDecBtn').addEventListener('click', (e) => {
        e.stopPropagation();
        _applyFontSize((parseInt(localStorage.getItem('fontSize') ?? '14') || 14) - 1);
    });
    document.getElementById('fontIncBtn').addEventListener('click', (e) => {
        e.stopPropagation();
        _applyFontSize((parseInt(localStorage.getItem('fontSize') ?? '14') || 14) + 1);
    });
    document.getElementById('sessionCopyBtn').addEventListener('click', () => {
        const sel = appState.terminal?.getSelection();
        if (sel) {
            void navigator.clipboard.writeText(sel).then(() => { toast('Copied'); }).catch(() => { toast('Copy failed'); });
        }
        else {
            toast('No text selected');
        }
        closeMenu();
    });
    document.getElementById('sessionResetBtn').addEventListener('click', () => {
        closeMenu();
        if (!appState.sshConnected)
            return;
        sendSSHInput('\x1bc');
        appState.terminal?.reset();
    });
    document.getElementById('sessionClearBtn').addEventListener('click', () => {
        closeMenu();
        appState.terminal?.clear();
    });
    document.getElementById('sessionRecordStartBtn').addEventListener('click', () => {
        closeMenu();
        startRecording();
    });
    document.getElementById('sessionRecordStopBtn').addEventListener('click', () => {
        closeMenu();
        stopAndDownloadRecording();
    });
    document.getElementById('sessionCtrlCBtn').addEventListener('click', () => {
        closeMenu();
        if (!appState.sshConnected)
            return;
        sendSSHInput('\x03');
    });
    document.getElementById('sessionCtrlZBtn').addEventListener('click', () => {
        closeMenu();
        if (!appState.sshConnected)
            return;
        sendSSHInput('\x1a');
    });
    document.getElementById('sessionReconnectBtn').addEventListener('click', () => {
        closeMenu();
        reconnect();
    });
    document.getElementById('sessionDisconnectBtn').addEventListener('click', () => {
        closeMenu();
        disconnect();
    });
    // Theme cycle — session-only (no localStorage write)
    document.getElementById('sessionThemeBtn').addEventListener('click', (e) => {
        e.stopPropagation();
        const idx = THEME_ORDER.indexOf(appState.activeThemeName);
        const next = THEME_ORDER[(idx + 1) % THEME_ORDER.length];
        _applyTheme(next, { persist: false });
    });
}
// ── Tab navigation ───────────────────────────────────────────────────────────
export function initTabBar() {
    _applyTabBarVisibility();
    document.querySelectorAll('.tab').forEach((tab) => {
        tab.addEventListener('click', () => {
            const panelId = tab.dataset.panel;
            document.querySelectorAll('.tab').forEach((t) => { t.classList.remove('active'); });
            document.querySelectorAll('.panel').forEach((p) => { p.classList.remove('active'); });
            tab.classList.add('active');
            document.getElementById(`panel-${panelId ?? ''}`)?.classList.add('active');
            if (panelId === 'terminal') {
                if (appState.hasConnected) {
                    appState.tabBarVisible = false;
                    _applyTabBarVisibility();
                }
                setTimeout(() => { appState.fitAddon?.fit(); focusIME(); }, 50);
            }
            else {
                appState.tabBarVisible = true;
                _applyTabBarVisibility();
            }
        });
    });
}
export function _applyTabBarVisibility() {
    document.getElementById('tabBar')?.classList.toggle('hidden', !appState.tabBarVisible);
    document.documentElement.style.setProperty('--tab-height', appState.tabBarVisible ? _ROOT_CSS.tabHeight : '0px');
}
function toggleTabBar() {
    appState.tabBarVisible = !appState.tabBarVisible;
    _applyTabBarVisibility();
    appState.fitAddon?.fit();
    appState.terminal?.scrollToBottom();
    if (appState.sshConnected && appState.ws?.readyState === WebSocket.OPEN) {
        appState.ws.send(JSON.stringify({ type: 'resize', cols: appState.terminal?.cols ?? 80, rows: appState.terminal?.rows ?? 24 }));
    }
}
function switchToTerminal() {
    document.querySelector('[data-panel="terminal"]')?.click();
}
// ── Connect form ─────────────────────────────────────────────────────────────
export function initConnectForm() {
    const form = document.getElementById('connectForm');
    const authType = document.getElementById('authType');
    authType.addEventListener('change', () => {
        const isKey = authType.value === 'key';
        document.getElementById('passwordGroup').style.display = isKey ? 'none' : 'block';
        document.getElementById('keyGroup').style.display = isKey ? 'block' : 'none';
    });
    form.addEventListener('submit', (e) => {
        e.preventDefault();
        const profile = {
            name: document.getElementById('profileName').value.trim() || 'Server',
            host: document.getElementById('host').value.trim(),
            port: parseInt(document.getElementById('port').value) || 22,
            username: document.getElementById('username').value.trim(),
            authType: authType.value,
            password: document.getElementById('password').value,
            privateKey: document.getElementById('privateKey').value.trim(),
            passphrase: document.getElementById('passphrase').value,
            initialCommand: document.getElementById('initialCommand').value.trim(),
        };
        document.getElementById('password').value = '';
        document.getElementById('passphrase').value = '';
        void saveProfile(profile);
        switchToTerminal();
        connect(profile);
    });
    document.getElementById('useStoredKeyBtn').addEventListener('click', () => {
        const keys = getKeys();
        if (!keys.length) {
            toast('No stored keys. Add one in the Keys tab.');
            return;
        }
        const key = keys[0];
        if (!key)
            return;
        document.getElementById('privateKey').value = key.vaultId;
        toast(`Using key: ${key.name}`);
    });
}
// ── Key bar ──────────────────────────────────────────────────────────────────
export function setCtrlActive(active) {
    appState.ctrlActive = active;
    document.getElementById('keyCtrl')?.classList.toggle('active', active);
}
function _attachRepeat(element, onRepeat, onPress) {
    let _delayTimer = null;
    let _intervalTimer = null;
    function _clear() {
        if (_delayTimer)
            clearTimeout(_delayTimer);
        if (_intervalTimer)
            clearInterval(_intervalTimer);
        _delayTimer = _intervalTimer = null;
    }
    element.addEventListener('pointerdown', (e) => {
        e.preventDefault();
        if (onPress)
            onPress();
        onRepeat();
        _delayTimer = setTimeout(() => {
            _intervalTimer = setInterval(onRepeat, KEY_REPEAT.INTERVAL_MS);
        }, KEY_REPEAT.DELAY_MS);
    });
    element.addEventListener('pointerup', () => { _clear(); setTimeout(focusIME, 50); });
    element.addEventListener('pointercancel', _clear);
    element.addEventListener('pointerleave', _clear);
    element.addEventListener('contextmenu', (e) => { e.preventDefault(); });
}
export function initTerminalActions() {
    document.getElementById('keyCtrl').addEventListener('click', () => {
        if ('vibrate' in navigator)
            navigator.vibrate(10);
        setCtrlActive(!appState.ctrlActive);
        focusIME();
    });
    const keys = {
        keyEsc: '\x1b',
        keyTab: '\t',
        keySlash: '/',
        keyPipe: '|',
        keyDash: '-',
        keyUp: '\x1b[A',
        keyDown: '\x1b[B',
        keyLeft: '\x1b[D',
        keyRight: '\x1b[C',
        keyHome: '\x1b[H',
        keyEnd: '\x1b[F',
        keyPgUp: '\x1b[5~',
        keyPgDn: '\x1b[6~',
    };
    for (const [id, seq] of Object.entries(keys)) {
        const el = document.getElementById(id);
        if (!el)
            continue;
        _attachRepeat(el, () => { sendSSHInput(seq); }, () => { if ('vibrate' in navigator)
            navigator.vibrate(10); });
    }
}
// ── Key bar visibility (#1) + IME/Direct mode (#2) ──────────────────────────
export function initKeyBar() {
    appState.keyBarVisible = localStorage.getItem('keyBarVisible') !== 'false';
    appState.imeMode = localStorage.getItem('imeMode') !== 'direct';
    _applyKeyBarVisibility();
    _applyImeModeUI();
    document.getElementById('handleChevron').addEventListener('click', toggleKeyBar);
    document.getElementById('tabBarToggleBtn').addEventListener('click', toggleTabBar);
    document.getElementById('keyModeBtn').addEventListener('click', () => {
        toggleImeMode();
        focusIME();
    });
}
function toggleKeyBar() {
    appState.keyBarVisible = !appState.keyBarVisible;
    localStorage.setItem('keyBarVisible', String(appState.keyBarVisible));
    _applyKeyBarVisibility();
    appState.fitAddon?.fit();
    appState.terminal?.scrollToBottom();
    if (appState.sshConnected && appState.ws?.readyState === WebSocket.OPEN) {
        appState.ws.send(JSON.stringify({ type: 'resize', cols: appState.terminal?.cols ?? 80, rows: appState.terminal?.rows ?? 24 }));
    }
}
function _applyKeyBarVisibility() {
    document.getElementById('key-bar')?.classList.toggle('hidden', !appState.keyBarVisible);
    const chevron = document.getElementById('handleChevron');
    if (chevron)
        chevron.textContent = appState.keyBarVisible ? '▾' : '▴';
    document.documentElement.style.setProperty('--keybar-height', appState.keyBarVisible ? _ROOT_CSS.keybarHeight : '0px');
}
function toggleImeMode() {
    appState.imeMode = !appState.imeMode;
    localStorage.setItem('imeMode', appState.imeMode ? 'ime' : 'direct');
    _applyImeModeUI();
    focusIME();
}
function _applyImeModeUI() {
    const btn = document.getElementById('keyModeBtn');
    if (!btn)
        return;
    btn.textContent = 'IME';
    btn.classList.toggle('ime-active', appState.imeMode);
}
//# sourceMappingURL=ui.js.map