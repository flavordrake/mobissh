/**
 * modules/settings.ts — Settings panel, service worker, and cache management
 *
 * Handles WS URL persistence, danger zone toggles, font/theme selectors,
 * clear data, and service worker registration.
 */

import type { SettingsDeps } from './types.js';
import { getDefaultWsUrl, THEMES, THEME_ORDER } from './constants.js';
import { resetKeyBarConfig } from './keybar-config.js';
import type { ThemeName } from './types.js';
import { showErrorDialog } from './ui.js';
import { getPreviewTimeout, setPreviewTimeout, getPreviewIdleDelay, setPreviewIdleDelay } from './ime.js';
import { getProfiles } from './profiles.js';


/** Declarative schema for validatable localStorage keys. */
const SETTING_SCHEMAS: Array<{ key: string; valid: string[]; defaultValue: string }> = [
  { key: 'imeDockPosition', valid: ['top', 'bottom'], defaultValue: 'top' },
  { key: 'imePreviewMode', valid: ['true', 'false'], defaultValue: 'true' },
  { key: 'imeMode', valid: ['ime', 'direct'], defaultValue: 'direct' },
  { key: 'keyControlsDock', valid: ['left', 'right'], defaultValue: 'right' },
];

/** Validate localStorage keys against current valid values. Remove invalid entries. */
export function migrateSettings(): void {
  for (const { key, valid, defaultValue } of SETTING_SCHEMAS) {
    const stored = localStorage.getItem(key);
    if (stored !== null && !valid.includes(stored)) {
      console.info(`[settings] migrated ${key}: "${stored}" → removed (default: ${defaultValue})`);
      localStorage.removeItem(key);
    }
  }
}

let _toast = (_msg: string): void => {};
let _applyFontSize = (_size: number): void => {};
let _applyTheme = (_name: string, _opts?: { persist?: boolean }): void => {};

export function initSettings({ toast, applyFontSize, applyTheme }: SettingsDeps): void {
  _toast = toast;
  _applyFontSize = applyFontSize;
  _applyTheme = applyTheme;
}

export function initSettingsPanel(): void {
  const wsInput = document.getElementById('wsUrl') as HTMLInputElement;
  wsInput.value = localStorage.getItem('wsUrl') ?? getDefaultWsUrl();

  const wsWarn = document.getElementById('wsWarnInsecure');
  if (wsWarn && wsInput.value.startsWith('ws://')) {
    wsWarn.classList.remove('hidden');
  }

  const wsWarnHost = document.getElementById('wsWarnHostMismatch');
  function updateHostMismatchWarning(url: string): void {
    if (!wsWarnHost) return;
    try {
      wsWarnHost.classList.toggle('hidden', new URL(url).host === location.host);
    } catch {
      wsWarnHost.classList.add('hidden');
    }
  }
  updateHostMismatchWarning(wsInput.value);

  wsInput.addEventListener('input', () => {
    updateHostMismatchWarning(wsInput.value);
  });

  // Danger Zone toggles
  const dangerAllowWsEl = document.getElementById('dangerAllowWs') as HTMLInputElement;
  dangerAllowWsEl.checked = localStorage.getItem('dangerAllowWs') === 'true';
  dangerAllowWsEl.addEventListener('change', () => {
    localStorage.setItem('dangerAllowWs', dangerAllowWsEl.checked ? 'true' : 'false');
  });

  document.getElementById('saveSettingsBtn')!.addEventListener('click', () => {
    const url = wsInput.value.trim();
    if (url.startsWith('ws://')) {
      if (dangerAllowWsEl.checked) {
        localStorage.setItem('wsUrl', url);
        updateHostMismatchWarning(url);
        if (wsWarn) wsWarn.classList.remove('hidden');
        _toast('Saved — warning: ws:// is unencrypted.');
      } else {
        _toast('ws:// is not allowed — use wss:// (or enable in Danger Zone)');
      }
      return;
    }
    if (!url.startsWith('wss://')) {
      _toast('URL must start with wss://');
      return;
    }
    localStorage.setItem('wsUrl', url);
    updateHostMismatchWarning(url);
    if (wsWarn) wsWarn.classList.add('hidden');
    _toast('Settings saved.');
  });

  const allowPrivateEl = document.getElementById('allowPrivateHosts') as HTMLInputElement | null;
  if (allowPrivateEl) {
    allowPrivateEl.checked = localStorage.getItem('allowPrivateHosts') === 'true';
    allowPrivateEl.addEventListener('change', () => {
      localStorage.setItem('allowPrivateHosts', String(allowPrivateEl.checked));
      _toast(allowPrivateEl.checked
        ? '⚠ Private address connections enabled.'
        : 'SSRF protection re-enabled.');
    });
  }

  const remoteClipEl = document.getElementById('enableRemoteClipboard') as HTMLInputElement | null;
  if (remoteClipEl) {
    remoteClipEl.checked = localStorage.getItem('enableRemoteClipboard') === 'true';
    remoteClipEl.addEventListener('change', () => {
      localStorage.setItem('enableRemoteClipboard', String(remoteClipEl.checked));
      _toast(remoteClipEl.checked
        ? '⚠ Remote clipboard enabled. Reload to apply.'
        : 'Remote clipboard disabled. Reload to apply.');
    });
  }

  const pinchEl = document.getElementById('enablePinchZoom') as HTMLInputElement | null;
  if (pinchEl) {
    pinchEl.checked = localStorage.getItem('enablePinchZoom') !== 'false';
    pinchEl.addEventListener('change', () => {
      localStorage.setItem('enablePinchZoom', pinchEl.checked ? 'true' : 'false');
    });
  }

  // Debug: show/hide IME textarea for compose/correction debugging
  const debugIMEEl = document.getElementById('debugIME') as HTMLInputElement | null;
  if (debugIMEEl) {
    const imeOn = localStorage.getItem('debugIME') === 'true';
    debugIMEEl.checked = imeOn;
    if (imeOn) document.body.classList.add('debug-ime');
    debugIMEEl.addEventListener('change', () => {
      localStorage.setItem('debugIME', debugIMEEl.checked ? 'true' : 'false');
      document.body.classList.toggle('debug-ime', debugIMEEl.checked);
    });
  }

  const natVEl = document.getElementById('naturalVerticalScroll') as HTMLInputElement | null;
  if (natVEl) {
    natVEl.checked = localStorage.getItem('naturalVerticalScroll') !== 'false';
    natVEl.addEventListener('change', () => {
      localStorage.setItem('naturalVerticalScroll', natVEl.checked ? 'true' : 'false');
    });
  }

  const natHEl = document.getElementById('naturalHorizontalScroll') as HTMLInputElement | null;
  if (natHEl) {
    natHEl.checked = localStorage.getItem('naturalHorizontalScroll') !== 'false';
    natHEl.addEventListener('change', () => {
      localStorage.setItem('naturalHorizontalScroll', natHEl.checked ? 'true' : 'false');
    });
  }

  const termNotifEl = document.getElementById('termNotifications') as HTMLInputElement | null;
  if (termNotifEl) {
    termNotifEl.checked = localStorage.getItem('termNotifications') === 'true';
    termNotifEl.addEventListener('change', () => {
      if (termNotifEl.checked) {
        void Notification.requestPermission().then((perm) => {
          if (perm === 'granted') {
            localStorage.setItem('termNotifications', 'true');
          } else {
            termNotifEl.checked = false;
            localStorage.setItem('termNotifications', 'false');
            _toast('Notification permission denied — toggle reverted.');
          }
        });
      } else {
        localStorage.setItem('termNotifications', 'false');
      }
    });
  }

  const notifBgOnlyEl = document.getElementById('notifBackgroundOnly') as HTMLInputElement | null;
  if (notifBgOnlyEl) {
    notifBgOnlyEl.checked = localStorage.getItem('notifBackgroundOnly') !== 'false';
    notifBgOnlyEl.addEventListener('change', () => {
      localStorage.setItem('notifBackgroundOnly', notifBgOnlyEl.checked ? 'true' : 'false');
    });
  }

  const notifCooldownEl = document.getElementById('notifCooldown') as HTMLSelectElement | null;
  if (notifCooldownEl) {
    notifCooldownEl.value = localStorage.getItem('notifCooldown') ?? '15000';
    notifCooldownEl.addEventListener('change', () => {
      localStorage.setItem('notifCooldown', notifCooldownEl.value);
    });
  }

  const testNotifBtn = document.getElementById('testNotifBtn');
  if (testNotifBtn) {
    testNotifBtn.addEventListener('click', () => {
      console.log('[settings] Test notification button clicked');
      if (!('Notification' in window)) {
        showErrorDialog('Notifications not supported in this browser.\n\nThe Notification API is not available.');
        return;
      }
      if (!('serviceWorker' in navigator)) {
        showErrorDialog('Service Worker not supported in this browser.\n\nPWA notifications require Service Worker support.');
        return;
      }
      console.log('[settings] Current permission:', Notification.permission);

      const sendNotification = (): void => {
        void navigator.serviceWorker.ready.then((reg) => {
          console.log('[settings] SW registration ready, showing notification');
          return reg.showNotification('MobiSSH', { body: 'Test notification', tag: 'mobissh-agent' });
        }).then(() => {
          console.log('[settings] Notification shown via SW');
          _toast('Notification sent.');
        }).catch((err: unknown) => {
          console.error('[settings] SW showNotification failed:', err);
          showErrorDialog(`Notification failed:\n\n${String(err)}`);
        });
      };

      if (Notification.permission === 'granted') {
        sendNotification();
        return;
      }
      void Notification.requestPermission().then((perm) => {
        console.log('[settings] Permission result:', perm);
        if (perm === 'granted') {
          sendNotification();
        } else {
          showErrorDialog(`Notification permission: ${perm}\n\nThe browser denied notification permission. Check your browser or OS notification settings for this site.`);
        }
      }).catch((err: unknown) => {
        console.error('[settings] requestPermission failed:', err);
        showErrorDialog(`Permission request failed:\n\n${String(err)}`);
      });
    });
  }

  document.getElementById('resetKeyBarBtn')?.addEventListener('click', () => {
    resetKeyBarConfig();
    location.reload();
  });

  const dockEl = document.getElementById('keyControlsDockLeft') as HTMLInputElement | null;
  if (dockEl) {
    dockEl.checked = localStorage.getItem('keyControlsDock') === 'left';
    dockEl.addEventListener('change', () => {
      const dock = dockEl.checked ? 'left' : 'right';
      localStorage.setItem('keyControlsDock', dock);
      document.documentElement.classList.toggle('key-dock-left', dock === 'left');
    });
  }

  const countdownEl = document.getElementById('previewCountdownDuration') as HTMLSelectElement | null;
  if (countdownEl) {
    countdownEl.value = String(getPreviewTimeout());
    countdownEl.addEventListener('change', () => {
      const val = countdownEl.value === 'Infinity' ? Infinity : Number(countdownEl.value);
      setPreviewTimeout(val);
    });
  }

  const idleEl = document.getElementById('previewIdleTimeout') as HTMLSelectElement | null;
  if (idleEl) {
    idleEl.value = String(getPreviewIdleDelay());
    idleEl.addEventListener('change', () => {
      setPreviewIdleDelay(Number(idleEl.value));
    });
  }

  document.getElementById('fontSize')!.addEventListener('input', (e) => {
    _applyFontSize(parseFloat((e.target as HTMLInputElement).value));
  });

  const themeSelect = document.getElementById('termThemeSelect') as HTMLSelectElement;
  const themePreview = document.getElementById('themePreview');
  // Populate theme options from THEME_ORDER — single source of truth
  for (const name of THEME_ORDER) {
    const opt = document.createElement('option');
    opt.value = name;
    opt.textContent = THEMES[name].label;
    themeSelect.appendChild(opt);
  }
  themeSelect.value = localStorage.getItem('termTheme') ?? 'dark';

  function updateThemePreview(name: string): void {
    if (!themePreview) return;
    const t = (name in THEMES) ? THEMES[name as ThemeName].theme : undefined;
    if (!t) return;
    themePreview.style.setProperty('--preview-bg', t.background);
    themePreview.style.setProperty('--preview-fg', t.foreground);
    themePreview.style.setProperty('--preview-cursor', t.cursor);
  }

  updateThemePreview(themeSelect.value);
  themeSelect.addEventListener('change', () => {
    _applyTheme(themeSelect.value, { persist: true });
    updateThemePreview(themeSelect.value);
  });

  const fontSelect = document.getElementById('termFontSelect') as HTMLSelectElement;
  fontSelect.value = localStorage.getItem('termFont') ?? 'monospace';
  fontSelect.addEventListener('change', () => {
    localStorage.setItem('termFont', fontSelect.value);
  });

  document.getElementById('resetAppBtn')!.addEventListener('click', () => {
    if (!confirm('Clear all stored keys, profiles, settings, and caches, then reload?')) return;
    void clearCacheAndReload();
  });

  document.getElementById('exportBackupBtn')?.addEventListener('click', () => {
    exportBackup();
  });

  const importBtn = document.getElementById('importBackupBtn');
  const importFile = document.getElementById('importBackupFile') as HTMLInputElement | null;
  if (importBtn && importFile) {
    importBtn.addEventListener('click', () => { importFile.click(); });
    importFile.addEventListener('change', () => {
      const file = importFile.files?.[0];
      if (file) void importBackup(file);
      importFile.value = '';
    });
  }

  const versionEl = document.getElementById('versionInfo');
  const versionMeta = document.querySelector<HTMLMetaElement>('meta[name="app-version"]');
  if (versionEl && versionMeta?.content) {
    const [version, hash] = versionMeta.content.split(':');
    versionEl.textContent = `MobiSSH v${version ?? '?'} \u00b7 ${hash ?? '?'}`;
  }
}

// Backup export/import

const BACKUP_VERSION = 1;

interface BackupFile {
  version: number;
  exported: string;
  profiles: unknown[];
  vault?: {
    encrypted: string | null;
    meta: string | null;
  };
}

export function exportBackup(): void {
  const profiles = getProfiles();
  const vaultData = localStorage.getItem('sshVault');
  const vaultMeta = localStorage.getItem('vaultMeta');

  const backup: BackupFile = {
    version: BACKUP_VERSION,
    exported: new Date().toISOString(),
    profiles,
    vault: {
      encrypted: vaultData,
      meta: vaultMeta,
    },
  };

  const blob = new Blob([JSON.stringify(backup, null, 2)], { type: 'application/json' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  const date = new Date().toISOString().slice(0, 10);
  a.download = `mobissh-backup-${date}.json`;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
  _toast(`Exported ${String(profiles.length)} profiles.`);
}

export async function importBackup(file: File): Promise<void> {
  let text: string;
  try {
    text = await file.text();
  } catch {
    _toast('Failed to read backup file.');
    return;
  }

  let backup: BackupFile;
  try {
    backup = JSON.parse(text) as BackupFile;
  } catch {
    _toast('Invalid backup file — not valid JSON.');
    return;
  }

  if (typeof backup.version !== 'number' || backup.version > BACKUP_VERSION) {
    _toast(`Unsupported backup version: ${String(backup.version)}`);
    return;
  }

  if (!Array.isArray(backup.profiles)) {
    _toast('Invalid backup file — missing profiles.');
    return;
  }

  // Upsert profiles (match on host+port+username)
  const existing = getProfiles();
  let imported = 0;
  for (const p of backup.profiles) {
    const profile = p as { host?: string; port?: number; username?: string };
    if (!profile.host || !profile.username) continue;
    const idx = existing.findIndex(
      (e) => e.host === profile.host &&
             String(e.port || 22) === String(profile.port || 22) &&
             e.username === profile.username
    );
    if (idx >= 0) {
      existing[idx] = p as typeof existing[0];
    } else {
      existing.push(p as typeof existing[0]);
    }
    imported++;
  }
  localStorage.setItem('sshProfiles', JSON.stringify(existing));

  // Import vault data (encrypted blob — stays encrypted)
  let credsImported = false;
  if (backup.vault?.encrypted) {
    localStorage.setItem('sshVault', backup.vault.encrypted);
    credsImported = true;
  }
  if (backup.vault?.meta) {
    localStorage.setItem('vaultMeta', backup.vault.meta);
  }

  const credMsg = credsImported ? ', credentials imported (enter vault passphrase to unlock)' : '';
  _toast(`Imported ${String(imported)} profiles${credMsg}`);
}

export function registerServiceWorker(): void {
  if (!('serviceWorker' in navigator)) return;
  navigator.serviceWorker.register('sw.js').then((reg) => {
    setInterval(() => { void reg.update(); }, 60_000);
  }).catch((err: unknown) => {
    console.warn('Service worker registration failed:', err);
  });
}

export async function clearCacheAndReload(): Promise<void> {
  try {
    const regs = await navigator.serviceWorker.getRegistrations();
    await Promise.all(regs.map((r) => r.unregister()));
  } catch { /* may not be available */ }
  try {
    const keys = await caches.keys();
    await Promise.all(keys.map((k) => caches.delete(k)));
  } catch { /* may not be available */ }
  try { localStorage.clear(); } catch { /* may not be available */ }
  try { sessionStorage.clear(); } catch { /* may not be available */ }
  location.reload();
}
