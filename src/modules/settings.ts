/**
 * modules/settings.ts — Settings panel, service worker, and cache management
 *
 * Handles WS URL persistence, danger zone toggles, font/theme selectors,
 * clear data, and service worker registration.
 */

import type { SettingsDeps } from './types.js';
import { getDefaultWsUrl, THEMES } from './constants.js';
import type { ThemeName } from './types.js';
import { showErrorDialog } from './ui.js';


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
          return reg.showNotification('MobiSSH', { body: 'Test notification' });
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

  // Agent hooks — detect installed agents and wire toggle handlers
  void initAgentHooks();

  const dockEl = document.getElementById('keyControlsDockLeft') as HTMLInputElement | null;
  if (dockEl) {
    dockEl.checked = localStorage.getItem('keyControlsDock') === 'left';
    dockEl.addEventListener('change', () => {
      const dock = dockEl.checked ? 'left' : 'right';
      localStorage.setItem('keyControlsDock', dock);
      document.documentElement.classList.toggle('key-dock-left', dock === 'left');
    });
  }

  document.getElementById('fontSize')!.addEventListener('input', (e) => {
    _applyFontSize(parseFloat((e.target as HTMLInputElement).value));
  });

  const themeSelect = document.getElementById('termThemeSelect') as HTMLSelectElement;
  const themePreview = document.getElementById('themePreview');
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

  const versionEl = document.getElementById('versionInfo');
  const versionMeta = document.querySelector<HTMLMetaElement>('meta[name="app-version"]');
  if (versionEl && versionMeta?.content) {
    const [version, hash] = versionMeta.content.split(':');
    versionEl.textContent = `MobiSSH v${version ?? '?'} \u00b7 ${hash ?? '?'}`;
  }
}

interface AgentInfo {
  name: string;
  id: string;
  installed: boolean;
  hookActive: boolean;
}

async function initAgentHooks(): Promise<void> {
  try {
    const resp = await fetch('/api/detect-agents');
    if (!resp.ok) return;
    const data = await resp.json() as { agents: AgentInfo[] };
    for (const agent of data.agents) {
      const row = document.querySelector<HTMLElement>(`.agent-hook-row[data-agent="${agent.id}"]`);
      const status = document.querySelector(`[data-agent-status="${agent.id}"]`);
      const toggle = document.getElementById(`agentHook${agent.id.charAt(0).toUpperCase() + agent.id.slice(1)}`) as HTMLInputElement | null;
      if (!row || !status || !toggle) continue;

      if (!agent.installed) {
        row.setAttribute('data-agent-state', 'not-installed');
        status.textContent = 'Not installed';
        toggle.disabled = true;
        continue;
      }

      row.setAttribute('data-agent-state', 'installed');
      status.textContent = agent.hookActive ? 'Hook active' : 'Installed';

      if (agent.id === 'claude') {
        toggle.disabled = false;
        toggle.checked = agent.hookActive;
        toggle.addEventListener('change', () => {
          const endpoint = toggle.checked ? '/api/install-hook' : '/api/uninstall-hook';
          void fetch(endpoint, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ agent: 'claude' }),
          }).then(async (r) => {
            if (r.ok) {
              status.textContent = toggle.checked ? 'Hook active' : 'Installed';
              _toast(toggle.checked ? 'Claude Code hook installed.' : 'Claude Code hook removed.');
            } else {
              toggle.checked = !toggle.checked;
              const err = await r.json() as { error?: string };
              _toast(`Hook update failed: ${err.error ?? 'unknown error'}`);
            }
          }).catch(() => {
            toggle.checked = !toggle.checked;
            _toast('Hook update failed: network error');
          });
        });
      } else if (agent.id === 'codex' || agent.id === 'gemini') {
        toggle.disabled = false;
        toggle.checked = agent.hookActive;
        const agentLabel = agent.name;
        toggle.addEventListener('change', () => {
          const endpoint = toggle.checked ? '/api/install-hook' : '/api/uninstall-hook';
          void fetch(endpoint, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ agent: agent.id }),
          }).then(async (r) => {
            if (r.ok) {
              status.textContent = toggle.checked ? 'Hook active' : 'Installed';
              _toast(toggle.checked ? `${agentLabel} hook installed.` : `${agentLabel} hook removed.`);
            } else {
              toggle.checked = !toggle.checked;
              const err = await r.json() as { error?: string };
              _toast(`Hook update failed: ${err.error ?? 'unknown error'}`);
            }
          }).catch(() => {
            toggle.checked = !toggle.checked;
            _toast('Hook update failed: network error');
          });
        });
      } else {
        // Other agents: show installed but hook not yet supported
        toggle.disabled = true;
        status.textContent = 'Installed (hooks coming soon)';
      }
    }
  } catch {
    // API not available — leave rows in "Checking…" state
  }
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
