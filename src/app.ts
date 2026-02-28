/**
 * MobiSSH PWA — Main application entry point
 *
 * Pure orchestration: imports all modules, wires dependencies via DI,
 * and sets up event delegation. No business logic lives here.
 */

import { initDebugOverlay } from './modules/debug.js';
import { initRecording } from './modules/recording.js';
import { initVault } from './modules/vault.js';
import { initVaultUI, promptVaultSetupOnStartup } from './modules/vault-ui.js';
import {
  initProfiles, getProfiles, loadProfiles,
  loadProfileIntoForm, deleteProfile,
  loadKeys, importKey, useKey, deleteKey,
} from './modules/profiles.js';
import { initSettings, initSettingsPanel, registerServiceWorker } from './modules/settings.js';
import { initConnection } from './modules/connection.js';
import { initIME, initIMEInput } from './modules/ime.js';
import {
  initUI, toast, setStatus, focusIME,
  _applyTabBarVisibility, initSessionMenu, initTabBar,
  initConnectForm, initTerminalActions, initKeyBar,
  initTerminalResizeObserver, initRouting, navigateToPanel,
} from './modules/ui.js';
import {
  ROOT_CSS, initTerminal, handleResize, initKeyboardAwareness,
  getKeyboardVisible, applyFontSize, applyTheme,
} from './modules/terminal.js';

declare global {
  interface Window {
    __appReady?: () => void;
    __appBootError?: (err: unknown) => void;
  }
}

// ── Startup ──

document.addEventListener('DOMContentLoaded', () => void (async () => {
  try {
    initDebugOverlay();
    initTerminal();
    initUI({ keyboardVisible: getKeyboardVisible, ROOT_CSS, applyFontSize, applyTheme });
    initIME({ handleResize, applyFontSize });
    initIMEInput();
    initTabBar();
    initConnectForm();
    initTerminalActions();
    initKeyBar();
    initTerminalResizeObserver();
    initRecording({ toast });
    initProfiles({ toast, navigateToConnect: () => { navigateToPanel('connect'); } });
    initSettings({ toast, applyFontSize, applyTheme });
    initConnection({ toast, setStatus, focusIME, applyTabBarVisibility: _applyTabBarVisibility });
    initSessionMenu();
    initSettingsPanel();
    loadProfiles();
    loadKeys();
    registerServiceWorker();
    initVaultUI({ toast });
    await initVault();
    initKeyboardAwareness();

    // Signal boot complete before vault prompt — the app is fully initialized,
    // event handlers attached, terminal ready. The vault setup is a user
    // interaction (first-run only), not a boot failure.
    if (typeof window.__appReady === 'function') window.__appReady();
    await promptVaultSetupOnStartup();

    // Event delegation for profile list
    const profileList = document.getElementById('profileList')!;
    profileList.addEventListener('click', (e) => {
      const target = e.target as HTMLElement;
      const btn = target.closest<HTMLElement>('[data-action]');
      if (btn) {
        e.stopPropagation();
        const idx = parseInt(btn.dataset.idx ?? '0');
        if (btn.dataset.action === 'edit') void loadProfileIntoForm(idx);
        else if (btn.dataset.action === 'delete') deleteProfile(idx);
        return;
      }
      const item = target.closest<HTMLElement>('.profile-item');
      if (item) void loadProfileIntoForm(parseInt(item.dataset.idx ?? '0'));
    });
    profileList.addEventListener('touchstart', (e) => {
      (e.target as HTMLElement).closest('.profile-item')?.classList.add('tapped');
    }, { passive: true });
    profileList.addEventListener('touchend', (e) => {
      (e.target as HTMLElement).closest('.profile-item')?.classList.remove('tapped');
    }, { passive: true });

    // Event delegation for key list
    document.getElementById('keyList')!.addEventListener('click', (e) => {
      const btn = (e.target as HTMLElement).closest<HTMLElement>('[data-action]');
      if (!btn) return;
      const idx = parseInt(btn.dataset.idx ?? '0');
      if (btn.dataset.action === 'use') void useKey(idx);
      else if (btn.dataset.action === 'delete') deleteKey(idx);
    });

    // Import key button
    document.getElementById('importKeyBtn')!.addEventListener('click', () => {
      const name = (document.getElementById('keyName') as HTMLInputElement).value.trim();
      const data = (document.getElementById('keyData') as HTMLTextAreaElement).value.trim();
      void importKey(name, data).then((ok) => {
        if (ok) {
          (document.getElementById('keyName') as HTMLInputElement).value = '';
          (document.getElementById('keyData') as HTMLTextAreaElement).value = '';
        }
      });
    });

    // Cold start routing (#137): hash > "has profiles" heuristic > terminal default
    initRouting(getProfiles().length > 0);

    // Apply saved font size (syncs all UI)
    applyFontSize(parseInt(localStorage.getItem('fontSize') ?? '14') || 14);
  } catch (err: unknown) {
    console.error('[mobissh] Boot failed:', err);
    if (typeof window.__appBootError === 'function') window.__appBootError(err);
  }
})());
