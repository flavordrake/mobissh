/**
 * MobiSSH PWA — Main application entry point
 *
 * Pure orchestration: imports all modules, wires dependencies via DI,
 * and sets up event delegation. No business logic lives here.
 */
import { initRecording } from './modules/recording.js';
import { initVault } from './modules/vault.js';
import { initVaultUI } from './modules/vault-ui.js';
import { initProfiles, getProfiles, loadProfiles, loadProfileIntoForm, deleteProfile, loadKeys, importKey, useKey, deleteKey, } from './modules/profiles.js';
import { initSettings, initSettingsPanel, registerServiceWorker } from './modules/settings.js';
import { initConnection } from './modules/connection.js';
import { initIME, initIMEInput } from './modules/ime.js';
import { initUI, toast, setStatus, focusIME, _applyTabBarVisibility, initSessionMenu, initTabBar, initConnectForm, initTerminalActions, initKeyBar, } from './modules/ui.js';
import { ROOT_CSS, initTerminal, handleResize, initKeyboardAwareness, getKeyboardVisible, applyFontSize, applyTheme, } from './modules/terminal.js';
// ── Startup ──
document.addEventListener('DOMContentLoaded', () => {
    try {
        initTerminal();
        initUI({ keyboardVisible: getKeyboardVisible, ROOT_CSS, applyFontSize, applyTheme });
        initIME({ handleResize, applyFontSize });
        initIMEInput();
        initTabBar();
        initConnectForm();
        initTerminalActions();
        initKeyBar();
        initRecording({ toast });
        initProfiles({ toast });
        initSettings({ toast, applyFontSize, applyTheme });
        initConnection({ toast, setStatus, focusIME, applyTabBarVisibility: _applyTabBarVisibility });
        initSessionMenu();
        initSettingsPanel();
        loadProfiles();
        loadKeys();
        registerServiceWorker();
        initVaultUI({ toast });
        void initVault();
        initKeyboardAwareness();
        // Event delegation for profile list
        const profileList = document.getElementById('profileList');
        profileList.addEventListener('click', (e) => {
            const target = e.target;
            const btn = target.closest('[data-action]');
            if (btn) {
                e.stopPropagation();
                const idx = parseInt(btn.dataset.idx ?? '0');
                if (btn.dataset.action === 'edit')
                    void loadProfileIntoForm(idx);
                else if (btn.dataset.action === 'delete')
                    deleteProfile(idx);
                return;
            }
            const item = target.closest('.profile-item');
            if (item)
                void loadProfileIntoForm(parseInt(item.dataset.idx ?? '0'));
        });
        profileList.addEventListener('touchstart', (e) => {
            e.target.closest('.profile-item')?.classList.add('tapped');
        }, { passive: true });
        profileList.addEventListener('touchend', (e) => {
            e.target.closest('.profile-item')?.classList.remove('tapped');
        }, { passive: true });
        // Event delegation for key list
        document.getElementById('keyList').addEventListener('click', (e) => {
            const btn = e.target.closest('[data-action]');
            if (!btn)
                return;
            const idx = parseInt(btn.dataset.idx ?? '0');
            if (btn.dataset.action === 'use')
                void useKey(idx);
            else if (btn.dataset.action === 'delete')
                deleteKey(idx);
        });
        // Import key button
        document.getElementById('importKeyBtn').addEventListener('click', () => {
            const name = document.getElementById('keyName').value.trim();
            const data = document.getElementById('keyData').value.trim();
            void importKey(name, data).then((ok) => {
                if (ok) {
                    document.getElementById('keyName').value = '';
                    document.getElementById('keyData').value = '';
                }
            });
        });
        // Cold start UX (#36): if profiles exist, land on Connect so user can tap to connect
        if (getProfiles().length > 0) {
            document.querySelector('[data-panel="connect"]')?.click();
        }
        // Apply saved font size (syncs all UI)
        applyFontSize(parseInt(localStorage.getItem('fontSize') ?? '14') || 14);
    }
    catch (err) {
        console.error('[mobissh] Boot failed:', err);
        if (typeof window.__appBootError === 'function')
            window.__appBootError(err);
    }
    if (typeof window.__appReady === 'function')
        window.__appReady();
});
//# sourceMappingURL=app.js.map