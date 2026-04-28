/**
 * MobiSSH PWA — Main application entry point
 *
 * Pure orchestration: imports all modules, wires dependencies via DI,
 * and sets up event delegation. No business logic lives here.
 */

import { initDebugOverlay, getDebugLines } from './modules/debug.js';
import { initBugReport } from './modules/bug-report.js';
import { initRecording } from './modules/recording.js';
import { initVault } from './modules/vault.js';
import { initVaultUI, promptVaultSetupOnStartup } from './modules/vault-ui.js';
import {
  initProfiles, getProfiles, loadProfiles,
  deleteProfile, editProfile, closeProfileEdit,
  loadKeys, importKey, deleteKey, renameKey, editKey, saveKeyEdit, cancelKeyEdit, populateKeyDropdown,
} from './modules/profiles.js';
import { initSettings, initSettingsPanel, registerServiceWorker, migrateSettings, connectSSE, applyUiScaleFromStorage } from './modules/settings.js';
import { initConnection } from './modules/connection.js';
import { appState, onStateChange } from './modules/state.js';
import { refreshKeepAliveNotification, dismissKeepAliveNotification } from './modules/keepalive-notification.js';
import { disconnect } from './modules/connection.js';
import { initIME, initIMEInput } from './modules/ime.js';
import { initSelection } from './modules/selection.js';
import {
  initUI, toast, setStatus, focusIME,
  _applyTabBarVisibility, initSessionMenu, initTabBar,
  initConnectForm, initTerminalActions, initApprovalBar, initKeyBar,
  initRouting, navigateToPanel,
  initFilesPanel, initLongPressTooltips,
} from './modules/ui.js';
import {
  getRootCSS, initTerminal, handleResize, initKeyboardAwareness,
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
    console.log('[boot] code version: 2026-04-04T2350-reconnect-guard-v3');
    migrateSettings();
    applyUiScaleFromStorage();
    initDebugOverlay();
    initTerminal();
    initUI({ keyboardVisible: getKeyboardVisible, ROOT_CSS: getRootCSS(), applyFontSize, applyTheme });
    initIME({ handleResize, applyFontSize });
    initIMEInput();
    initSelection();
    initTabBar();
    initConnectForm();
    initTerminalActions();
    initApprovalBar();
    initKeyBar();
    initFilesPanel();
    initLongPressTooltips();
    initRecording({ toast });
    initBugReport({ getDebugLines, toast });
    initProfiles({ toast, navigateToConnect: () => { navigateToPanel('connect'); } });
    initSettings({ toast, applyFontSize, applyTheme });
    initConnection({ toast, setStatus, focusIME, applyTabBarVisibility: _applyTabBarVisibility });
    initSessionMenu();
    initSettingsPanel();
    loadProfiles();
    loadKeys();
    populateKeyDropdown();
    registerServiceWorker();

    // Cache telemetry: log what caches exist and their sizes at boot
    if ('caches' in window) {
      void caches.keys().then(async (keys) => {
        console.log(`[cache] ${String(keys.length)} cache(s): ${keys.join(', ') || '(none)'}`);
        for (const key of keys) {
          const cache = await caches.open(key);
          const entries = await cache.keys();
          console.log(`[cache] ${key}: ${String(entries.length)} entries`);
        }
      });
    }

    // SSE channel: real-time version staleness detection.
    // Server pushes its version on connect. After a container restart,
    // EventSource auto-reconnects and the new server version triggers
    // a stale warning if the running code is outdated.
    connectSSE();

    // Version stale event: toast + notification so user knows to reload
    window.addEventListener('version-stale', ((e: CustomEvent) => {
      const { local, server } = e.detail as { local: { version: string; hash: string }; server: { version: string; hash: string } };
      toast(`Update available: ${server.version}:${server.hash} (running ${local.version}:${local.hash}). Long-press Settings to reload.`);
    }) as EventListener);

    // Keep-alive ongoing notification: refresh on every state transition.
    // The module is idempotent and a no-op when the setting is off.
    onStateChange(() => { void refreshKeepAliveNotification(); });

    // SW → page channel for the "Disconnect all" notification action.
    if ('serviceWorker' in navigator) {
      navigator.serviceWorker.addEventListener('message', (e: MessageEvent) => {
        const data = e.data as { type?: string } | null;
        if (data?.type !== 'keepalive-disconnect-all') return;
        const ids = Array.from(appState.sessions.keys());
        for (const id of ids) {
          try { disconnect(id); } catch (err) { console.warn('[keepalive] disconnect failed:', id, err); }
        }
        void dismissKeepAliveNotification();
        toast('Disconnected all sessions from notification.');
      });
    }

    initVaultUI({ toast });
    await initVault();
    initKeyboardAwareness();

    // Signal boot complete before vault prompt — the app is fully initialized,
    // event handlers attached, terminal ready. The vault setup is a user
    // interaction (first-run only), not a boot failure.
    if (typeof window.__appReady === 'function') window.__appReady();
    await promptVaultSetupOnStartup();

    // Vault is now ready — reload profiles so saved credentials appear (#384)
    loadProfiles();

    // Cold start: if no active sessions, show Connect panel instead of empty terminal
    if (appState.sessions.size === 0) {
      navigateToPanel('connect');
    }

    // Event delegation for profile list
    const profileList = document.getElementById('profileList')!;
    profileList.addEventListener('click', (e) => {
      const target = e.target as HTMLElement;
      const btn = target.closest<HTMLElement>('[data-action]');
      if (btn) {
        e.stopPropagation();
        const idx = parseInt(btn.dataset.idx ?? '0');
        if (btn.dataset.action === 'edit') editProfile(idx);
        else if (btn.dataset.action === 'delete') deleteProfile(idx);
        else if (btn.dataset.action === 'close-edit') { closeProfileEdit(); loadProfiles(); }
        return;
      }
    });
    profileList.addEventListener('touchstart', (e) => {
      (e.target as HTMLElement).closest('.profile-item')?.classList.add('tapped');
    }, { passive: true });
    profileList.addEventListener('touchend', (e) => {
      (e.target as HTMLElement).closest('.profile-item')?.classList.remove('tapped');
    }, { passive: true });

    // Event delegation for key list (inline in Connect panel, #441)
    document.getElementById('keyList')!.addEventListener('click', (e) => {
      const btn = (e.target as HTMLElement).closest<HTMLElement>('[data-action]');
      if (!btn) return;
      const idx = parseInt(btn.dataset.idx ?? '0');
      if (btn.dataset.action === 'delete') deleteKey(idx);
      else if (btn.dataset.action === 'edit') void editKey(idx);
      else if (btn.dataset.action === 'save-edit') void saveKeyEdit(idx);
      else if (btn.dataset.action === 'cancel-edit') cancelKeyEdit(idx);
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
