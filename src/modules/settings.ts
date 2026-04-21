/**
 * modules/settings.ts — Settings panel, service worker, and cache management
 *
 * Handles WS URL persistence, danger zone toggles, font/theme selectors,
 * clear data, and service worker registration.
 */

import type { SettingsDeps } from './types.js';
import { getDefaultWsUrl, THEMES, THEME_ORDER, parseApprovalPayload } from './constants.js';
import { resetKeyBarConfig } from './keybar-config.js';
import type { ThemeName } from './types.js';
import { showErrorDialog } from './ui.js';
import { getPreviewTimeout, setPreviewTimeout, getPreviewIdleDelay, setPreviewIdleDelay } from './ime.js';
import { getProfiles, loadProfiles } from './profiles.js';


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

/** Show the Settings overview (category list). */
export function showSettingsOverview(): void {
  document.getElementById('settingsOverview')?.classList.remove('hidden');
  document.querySelectorAll<HTMLElement>('.settings-detail').forEach((el) => {
    el.classList.remove('active');
  });
}

function _showSettingsDetail(name: string): void {
  document.getElementById('settingsOverview')?.classList.add('hidden');
  document.querySelectorAll<HTMLElement>('.settings-detail').forEach((el) => {
    el.classList.toggle('active', el.dataset.section === name);
  });
}

export function initSettingsPanel(): void {
  // Overview / detail routing
  document.querySelectorAll<HTMLElement>('.settings-category').forEach((btn) => {
    btn.addEventListener('click', () => {
      const name = btn.dataset.section;
      if (!name) return;
      _showSettingsDetail(name);
    });
  });
  document.querySelectorAll<HTMLElement>('.settings-detail-back').forEach((btn) => {
    btn.addEventListener('click', () => { showSettingsOverview(); });
  });

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

  const approvalBarEl = document.getElementById('enableApprovalBar') as HTMLInputElement | null;
  if (approvalBarEl) {
    approvalBarEl.checked = localStorage.getItem('approvalBarDisabled') !== 'true';
    approvalBarEl.addEventListener('change', () => {
      if (approvalBarEl.checked) {
        localStorage.removeItem('approvalBarDisabled');
        _toast('Approval bar enabled.');
      } else {
        localStorage.setItem('approvalBarDisabled', 'true');
        _toast('Approval bar disabled.');
      }
    });
  }

  // Default approval mode — syncs with server
  const approvalModeEl = document.getElementById('approvalDefaultMode') as HTMLSelectElement | null;
  if (approvalModeEl) {
    // Load current mode from server
    void fetch('api/approval-mode').then((r) => r.json()).then((data: { mode?: string }) => {
      if (data.mode) approvalModeEl.value = data.mode;
    }).catch(() => { /* offline */ });

    approvalModeEl.addEventListener('change', () => {
      void fetch('api/approval-mode', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ mode: approvalModeEl.value }),
      }).then(() => {
        _toast(`Default approval: ${approvalModeEl.value}`);
      }).catch(() => {
        _toast('Failed to update approval mode');
      });
    });
  }

  const approvalCountdownEl = document.getElementById('approvalCountdown') as HTMLSelectElement | null;
  if (approvalCountdownEl) {
    approvalCountdownEl.value = localStorage.getItem('approvalCountdown') ?? '0';
    approvalCountdownEl.addEventListener('change', () => {
      localStorage.setItem('approvalCountdown', approvalCountdownEl.value);
      const sec = parseInt(approvalCountdownEl.value, 10);
      _toast(sec > 0 ? `Auto-accept: ${String(sec)}s` : 'Auto-accept disabled');
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

  // Import vault data (encrypted blob — stays encrypted).
  //
  // Bio enrollment is device-specific: dekBio in vaultMeta is the DEK wrapped
  // by a KEK derived from THIS DEVICE's WebAuthn PRF output. The imported
  // dekBio was wrapped on a different device with a different credential, so
  // it cannot be unwrapped here — every fingerprint touch would fail silently
  // and leak through to a manual password prompt (issue: vault-import-reprompt).
  //
  // Strip dekBio from imported meta and clear any local WebAuthn handles.
  // After unlocking with the master password once, the user can re-enroll
  // bio in Settings, which re-wraps the live DEK with this device's KEK.
  let credsImported = false;
  if (backup.vault?.encrypted) {
    localStorage.setItem('sshVault', backup.vault.encrypted);
    credsImported = true;
  }
  let bioStripped = false;
  if (backup.vault?.meta) {
    let meta: { dekBio?: unknown } = {};
    try {
      meta = JSON.parse(backup.vault.meta) as { dekBio?: unknown };
    } catch {
      meta = {};
    }
    if (meta.dekBio !== undefined) {
      delete meta.dekBio;
      bioStripped = true;
    }
    localStorage.setItem('vaultMeta', JSON.stringify(meta));
    // The imported credId/salt would point to a non-existent credential on
    // this device (or worse, a stale enrollment for a different vault).
    // Clear them so tryUnlockVault doesn't even attempt biometric.
    localStorage.removeItem('webauthnCredId');
    localStorage.removeItem('webauthnPrfSalt');
  }

  let credMsg = '';
  if (credsImported) {
    credMsg = bioStripped
      ? ', credentials imported (enter password; re-enable Touch ID in Settings)'
      : ', credentials imported (enter vault passphrase to unlock)';
  }
  _toast(`Imported ${String(imported)} profiles${credMsg}`);

  // Re-render the Connect panel so the imported profiles appear immediately.
  // Without this, the panel keeps showing whatever was rendered at cold start
  // (often the empty "Add Connection" UI), and the user has to fully kill the
  // app to see imported profiles.
  loadProfiles();
}

export function registerServiceWorker(): void {
  if (!('serviceWorker' in navigator)) return;

  // Detect when a new SW takes control (update activated).
  // Log for debug overlay telemetry — the new SW is already active at this point.
  navigator.serviceWorker.addEventListener('controllerchange', () => {
    console.log('[sw] controllerchange — new service worker activated');
  });

  navigator.serviceWorker.register('sw.js').then((reg) => {
    setInterval(() => { void reg.update(); }, 60_000);

    // Log SW state for telemetry
    if (reg.active) console.log(`[sw] active: ${reg.active.scriptURL}`);
    if (reg.waiting) console.log('[sw] waiting worker detected — will activate on next navigation');
    if (reg.installing) console.log('[sw] installing worker detected');

    reg.addEventListener('updatefound', () => {
      console.log('[sw] updatefound — new version downloading');
      const newWorker = reg.installing;
      if (newWorker) {
        newWorker.addEventListener('statechange', () => {
          console.log(`[sw] new worker state: ${newWorker.state}`);
        });
      }
    });
  }).catch((err: unknown) => {
    console.warn('Service worker registration failed:', err);
  });
}

/**
 * Connect to the server's SSE channel for real-time push events.
 *
 * Events:
 *   - version: server version on connect (staleness detection on reconnect)
 *   - approval: permission request from Claude Code hooks (shows approval bar)
 *   - hook: non-approval hook events (log + background notifications)
 *
 * EventSource auto-reconnects, so after a container restart the client
 * re-establishes, gets the new version, and detects stale code immediately.
 */
export function connectSSE(): void {
  const meta = document.querySelector<HTMLMetaElement>('meta[name="app-version"]');
  const localContent = meta?.content ?? '';
  const [localVersion, localHash] = localContent.split(':');

  if (!localContent) {
    console.warn('[sse] no app-version meta tag — running from cache?');
  }

  const es = new EventSource('events');

  // ── Version staleness detection ──
  es.addEventListener('version', (e: Event) => {
    const me = e as MessageEvent;
    try {
      const data = JSON.parse(me.data as string) as { version: string; hash: string; uptime: number };
      console.log(`[sse] server version: ${data.version}:${data.hash} (uptime ${String(Math.round(data.uptime))}s)`);

      if (!localHash) return;

      if (localHash === data.hash) {
        console.log(`[sse] fresh — ${localVersion ?? '?'}:${localHash}`);
      } else {
        console.warn(`[sse] STALE — running ${localVersion ?? '?'}:${localHash}, server has ${data.version}:${data.hash}`);
        window.dispatchEvent(new CustomEvent('version-stale', {
          detail: {
            local: { version: localVersion, hash: localHash },
            server: { version: data.version, hash: data.hash },
          },
        }));
      }
    } catch {
      console.warn('[sse] failed to parse version event');
    }
  });

  // ── Approval prompts from Claude Code hooks ──
  es.addEventListener('approval', (e: Event) => {
    const me = e as MessageEvent;
    try {
      const raw = JSON.parse(me.data as string) as Record<string, unknown>;
      const ap = parseApprovalPayload(raw);
      console.log(`[sse] approval: ${ap.label}`);
      window.dispatchEvent(new CustomEvent('approval-prompt', {
        detail: {
          phase: 'ready',
          sessionId: '',
          requestId: ap.requestId,
          tool: ap.toolName,
          detail: ap.command,
          description: ap.label,
          source: ap.source,
          options: [
            { key: '1', label: 'Yes' },
            { key: '2', label: 'No' },
          ],
        },
      }));
    } catch {
      console.warn('[sse] failed to parse approval event');
    }
  });

  // ── Hook events (non-approval) ──
  es.addEventListener('hook', (e: Event) => {
    const me = e as MessageEvent;
    try {
      const data = JSON.parse(me.data as string) as { event?: string; tool?: string; detail?: string; description?: string };
      console.log('[sse]', data.event, data.tool, data.detail);
    } catch {
      console.warn('[sse] failed to parse hook event');
    }
  });

  es.addEventListener('open', () => {
    console.log('[sse] connected');
  });

  es.addEventListener('error', () => {
    // EventSource auto-reconnects — just log for telemetry
    console.log('[sse] disconnected (will auto-reconnect)');
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
