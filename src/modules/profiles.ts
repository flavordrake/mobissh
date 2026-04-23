/**
 * modules/profiles.ts — Profile & key storage
 *
 * Manages saved SSH connection profiles and imported private keys.
 * Profile metadata is stored in localStorage; credentials are encrypted
 * in the vault (never plaintext).
 */

import type { ProfilesDeps, SSHProfile, ThemeName } from './types.js';
import { appState, isSessionConnected } from './state.js';
import { escHtml, THEMES, THEME_ORDER } from './constants.js';
import { vaultStore, vaultLoad, vaultDelete } from './vault.js';
import { ensureVaultKeyWithUI } from './vault-ui.js';
import { connect } from './connection.js';

export { escHtml };

/** Effective accent color for a profile. Uses the explicit `color` when set,
 *  otherwise falls back to the chosen theme's accent, otherwise the default
 *  theme's accent. Accepts both SSHProfile and StoredProfile-shaped inputs —
 *  the theme field may be a loose string loaded from localStorage. */
export function profileColor(profile: { color?: string; theme?: string }): string {
  if (profile.color) return profile.color;
  const theme = profile.theme && profile.theme in THEMES ? (profile.theme as ThemeName) : 'dark';
  return THEMES[theme].app.accent;
}

// ── Recent sessions persistence (#385) ──────────────────────────────────────

const RECENT_SESSIONS_KEY = 'recentSessions';
const MAX_RECENT = 5;

interface RecentSessionEntry {
  host: string;
  port: number;
  username: string;
  profileIdx: number;
}

/** Save a profile identity to the recent sessions list (newest first, deduplicated). */
export function saveRecentSession(profile: { host: string; port: number; username: string }, idx: number): void {
  const recent = getRecentSessions();
  // Remove duplicate (same host+port+username) — recentSession dedup via filter on host, port, username
  const deduped = recent.filter((e) => !(e.host === profile.host && e.port === (profile.port || 22) && e.username === profile.username));
  // Prepend newest, cap at MAX_RECENT
  deduped.unshift({ host: profile.host, port: profile.port || 22, username: profile.username, profileIdx: idx });
  localStorage.setItem(RECENT_SESSIONS_KEY, JSON.stringify(deduped.slice(0, MAX_RECENT)));
}

/** Get the recent sessions list from localStorage. */
export function getRecentSessions(): RecentSessionEntry[] {
  try {
    const raw = localStorage.getItem(RECENT_SESSIONS_KEY);
    if (!raw) return [];
    return JSON.parse(raw) as RecentSessionEntry[];
  } catch {
    return [];
  }
}

/** Remove a session from the recent list by host+port+username. */
export function removeRecentSession(host: string, port: number, username: string): void {
  const recent = getRecentSessions();
  const filtered = recent.filter(
    (e) => !(e.host === host && e.port === (port || 22) && e.username === username)
  );
  localStorage.setItem(RECENT_SESSIONS_KEY, JSON.stringify(filtered));
}

let _toast = (_msg: string): void => {};
let _navigateToConnect = (): void => {};

export function initProfiles({ toast, navigateToConnect }: ProfilesDeps): void {
  _toast = toast;
  _navigateToConnect = navigateToConnect;

  // Populate profile theme dropdown from THEME_ORDER — single source of truth
  const profileThemeEl = document.getElementById('profileTheme') as HTMLSelectElement | null;
  if (profileThemeEl) {
    for (const name of THEME_ORDER) {
      const opt = document.createElement('option');
      opt.value = name;
      opt.textContent = THEMES[name].label;
      profileThemeEl.appendChild(opt);
    }
  }

  // Profile color input wiring. When the user changes the theme, auto-update
  // the color to the new theme's accent unless they've explicitly chosen a
  // color. When the user picks a color, mark it explicit so a later theme
  // change doesn't clobber it. Reset returns control to the theme.
  const profileColorEl = document.getElementById('profileColor') as HTMLInputElement | null;
  const profileColorResetBtn = document.getElementById('profileColorReset');
  if (profileColorEl) {
    profileColorEl.addEventListener('input', () => {
      profileColorEl.dataset.explicit = '1';
    });
  }
  if (profileThemeEl && profileColorEl) {
    profileThemeEl.addEventListener('change', () => {
      if (profileColorEl.dataset.explicit === '1') return;
      const name = (profileThemeEl.value || 'dark') as ThemeName;
      profileColorEl.value = THEMES[name].app.accent;
    });
  }
  if (profileColorResetBtn && profileColorEl && profileThemeEl) {
    profileColorResetBtn.addEventListener('click', () => {
      const name = (profileThemeEl.value || 'dark') as ThemeName;
      profileColorEl.value = THEMES[name].app.accent;
      profileColorEl.dataset.explicit = '';
    });
  }
}

// Profile storage

interface StoredProfile {
  title: string;
  host: string;
  port: number;
  username: string;
  authType: string;
  initialCommand: string;
  vaultId: string;
  hasVaultCreds?: boolean;
  keyVaultId?: string;
  theme?: string;
  color?: string;
}

export function getProfiles(): StoredProfile[] {
  const raw = JSON.parse(localStorage.getItem('sshProfiles') || '[]') as StoredProfile[];
  let migrated = false;
  for (const p of raw) {
    // Migrate name → title for profiles saved before #425
    const rec = p as unknown as Record<string, unknown>;
    if ('name' in rec && !('title' in rec)) {
      rec.title = rec.name ?? '';
      delete rec.name;
      migrated = true;
    }
  }
  if (migrated) localStorage.setItem('sshProfiles', JSON.stringify(raw));
  return raw;
}

function _generateId(): string {
  return crypto.randomUUID();
}

export async function saveProfile(profile: SSHProfile): Promise<void> {
  const profiles = getProfiles();

  const existingIdx = profiles.findIndex(
    (p) => p.host === profile.host &&
           String(p.port || 22) === String(profile.port || 22) &&
           p.username === profile.username
  );

  const vaultId = existingIdx >= 0
    ? (profiles[existingIdx]?.vaultId ?? _generateId())
    : _generateId();

  // Check if the form selected a stored key by its vaultId
  const selectedKeyId = (document.getElementById('selectedKeyId') as HTMLSelectElement | null)?.value || '';
  const usingStoredKey = profile.authType === 'key' && selectedKeyId !== '' && selectedKeyId !== 'manual';

  // Read per-profile theme from form (may also be set on profile if passed directly)
  const profileThemeEl = document.getElementById('profileTheme') as HTMLSelectElement | null;
  const profileTheme = profile.theme ?? (profileThemeEl?.value || undefined);

  // Per-profile color. When the form input equals the theme accent, treat as
  // "unset" so changing the theme later still auto-updates the color. The
  // reset button also clears it explicitly (see the form wiring below).
  const profileColorEl = document.getElementById('profileColor') as HTMLInputElement | null;
  const colorRaw = profile.color ?? (profileColorEl?.dataset.explicit === '1' ? profileColorEl.value : undefined);
  const themeAccent = profileTheme ? THEMES[profileTheme as ThemeName].app.accent : THEMES.dark.app.accent;
  const profileColor = colorRaw && colorRaw.toLowerCase() !== themeAccent.toLowerCase() ? colorRaw : undefined;

  const saved: StoredProfile = {
    title: profile.title,
    host: profile.host,
    port: profile.port,
    username: profile.username,
    authType: profile.authType,
    initialCommand: profile.initialCommand ?? '',
    vaultId,
    ...(profileTheme ? { theme: profileTheme } : {}),
    ...(profileColor ? { color: profileColor } : {}),
  };

  if (usingStoredKey) {
    saved.keyVaultId = selectedKeyId;
  }

  const creds: Record<string, string> = {};
  if (profile.password) creds.password = profile.password;
  // Only store inline key if not using a stored key reference
  if (profile.privateKey && !usingStoredKey) creds.privateKey = profile.privateKey;
  if (profile.passphrase && !usingStoredKey) creds.passphrase = profile.passphrase;

  const hasVault = await ensureVaultKeyWithUI();
  if (hasVault && Object.keys(creds).length) {
    await vaultStore(vaultId, creds);
    saved.hasVaultCreds = true;
  } else if (!hasVault && Object.keys(creds).length) {
    _toast('Credentials not saved — vault setup cancelled.');
  }

  if (existingIdx >= 0) {
    profiles[existingIdx] = saved;
  } else {
    profiles.push(saved);
  }
  localStorage.setItem('sshProfiles', JSON.stringify(profiles));
  loadProfiles();
}

export function loadProfiles(): void {
  const profiles = getProfiles();
  const list = document.getElementById('profileList');
  const sessionList = document.getElementById('activeSessionList');
  if (!list) return;

  const formSection = document.getElementById('connect-form-section') as HTMLDetailsElement | null;

  // Render active sessions section (#306)
  const allSessions = Array.from(appState.sessions.values()).filter((s) => s.profile);
  if (sessionList) {
    if (allSessions.length > 0) {
      const hasDropped = allSessions.some((s) => !isSessionConnected(s));
      const reconnectAllBtn = hasDropped
        ? '<button class="item-btn accent reconnect-all-btn" data-action="reconnect-all">Reconnect all</button>'
        : '';
      sessionList.innerHTML = '<h3 class="section-label">Active Sessions</h3>'
        + allSessions.map((s) => {
          const stateClass = `session-state-${s.state}`;
          // State class drives visual treatment (solid when connected, pulse
          // when connecting, desaturated when dropped). Color comes from the
          // profile so the same color = same profile wherever it appears.
          const stateDot = isSessionConnected(s) ? 'dot-connected' : s.state === 'reconnecting' || s.state === 'connecting' ? 'dot-connecting' : 'dot-dropped';
          const color = s.profile ? profileColor(s.profile) : 'var(--accent)';
          const label = s.profile
            ? escHtml(s.profile.title || `${s.profile.username}@${s.profile.host}`)
            : escHtml(s.id);
          const actionBtn = isSessionConnected(s)
            ? `<button class="item-btn accent" data-action="switch" data-session-id="${escHtml(s.id)}">Switch</button>`
            : `<button class="item-btn accent" data-action="reconnect" data-session-id="${escHtml(s.id)}">Reconnect</button>`;
          return `<div class="active-session-item ${stateClass}" data-session-id="${escHtml(s.id)}" style="--profile-color:${escHtml(color)}">
            <span class="session-dot ${stateDot}" style="background:${escHtml(color)}"></span>
            <span class="session-label">${label}</span>
            ${actionBtn}
            <button class="item-btn danger" data-action="close-session" data-session-id="${escHtml(s.id)}">✕</button>
          </div>`;
        }).join('')
        + reconnectAllBtn;
    } else {
      sessionList.innerHTML = '';
    }
  }

  // Render recent sessions on cold start (#385)
  const recentSessions = getRecentSessions();
  if (allSessions.length === 0 && recentSessions.length > 0) {
    const reconnectAllBtn = recentSessions.length >= 2
      ? '<button class="item-btn accent reconnect-all-btn" data-action="reconnect-all-recent">Reconnect All</button>'
      : '';
    const recentHtml = '<h3 class="section-label">Recent Sessions</h3>'
      + recentSessions.map((r) => {
        const profile = profiles[r.profileIdx];
        const label = profile?.title
          ? escHtml(profile.title)
          : `${escHtml(r.username)}@${escHtml(r.host)}:${String(r.port)}`;
        const color = profile ? profileColor(profile) : 'var(--accent)';
        return `<div class="recent-session-item" data-idx="${String(r.profileIdx)}" style="--profile-color:${escHtml(color)}">
          <span class="session-dot" style="background:${escHtml(color)}"></span>
          <span class="session-label">${label}</span>
          <button class="item-btn accent" data-action="reconnect-recent" data-idx="${String(r.profileIdx)}">Reconnect</button>
          <button class="item-btn danger" data-action="remove-recent" data-host="${escHtml(r.host)}" data-port="${String(r.port)}" data-username="${escHtml(r.username)}" aria-label="Remove from recent">✕</button>
        </div>`;
      }).join('')
      + reconnectAllBtn;
    if (sessionList) {
      sessionList.innerHTML = recentHtml;
    }
  }

  if (!profiles.length) {
    list.innerHTML = '<p class="empty-hint">No saved profiles yet.</p>';
    if (formSection) {
      formSection.open = true;
      _updateFormSummary('New Connection');
    }
    return;
  }

  // Profiles section — only show header when active sessions exist above (#306)
  const profilesHeader = allSessions.length > 0 ? '<h3 class="section-label">Profiles</h3>' : '';
  list.innerHTML = profilesHeader
    + profiles.map((p, i) => {
      const matchingSessions = allSessions.filter(
        (s) => s.profile!.host === p.host && (s.profile!.port || 22) === (p.port || 22) && s.profile!.username === p.username
      );
      const hasSession = matchingSessions.length > 0;
      const isConnecting = matchingSessions.some((s) => s.state === 'connecting' || s.state === 'authenticating' || s.state === 'reconnecting');
      const connClass = hasSession ? ' profile-connected' : '';
      const connectBtnClass = isConnecting ? 'item-btn connecting' : 'item-btn';
      const connectBtnText = isConnecting ? 'Connecting…' : 'Connect';
      const color = profileColor(p);
      return `<div class="profile-item${connClass}" data-idx="${String(i)}" style="--profile-color:${escHtml(color)}">
        <span class="profile-name">${escHtml(p.title || `${p.username}@${p.host}`)}</span>
        <span class="profile-host">${escHtml(p.username)}@${escHtml(p.host)}:${String(p.port || 22)}</span>
        <div class="item-actions">
          <button class="item-btn" data-action="edit" data-idx="${String(i)}">Edit</button>
          <button class="${connectBtnClass}" data-action="connect" data-idx="${String(i)}">${connectBtnText}</button>
          <button class="item-btn danger" data-action="delete" data-idx="${String(i)}">Delete</button>
        </div>
      </div>`;
    }).join('');

  if (formSection) {
    formSection.open = false;
    _updateFormSummary('New Connection');
  }
}

/** Update the summary text of the connect form details element. */
function _updateFormSummary(text: string): void {
  const summary = document.querySelector('#connect-form-section > summary');
  if (summary) summary.textContent = text;
}

/** Reveal the connect form section. */
export function revealConnectForm(): void {
  const section = document.getElementById('connect-form-section') as HTMLDetailsElement | null;
  if (section) {
    section.open = true;
    section.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
  }
}

/** Reset form for a brand-new connection and reveal it. */
export function newConnection(): void {
  const form = document.getElementById('connectForm') as HTMLFormElement | null;
  if (form) form.reset();
  (document.getElementById('port') as HTMLInputElement).value = '22';
  const keySelect = document.getElementById('selectedKeyId') as HTMLSelectElement | null;
  if (keySelect) keySelect.value = '';
  document.getElementById('manualKeyGroup')?.classList.add('hidden');
  _updateFormSummary('New Connection');
  revealConnectForm();
  (document.getElementById('host') as HTMLInputElement).focus();
}

export async function loadProfileIntoForm(idx: number): Promise<void> {
  const profile = getProfiles()[idx];
  if (!profile) return;

  (document.getElementById('profileName') as HTMLInputElement).value = profile.title || '';
  (document.getElementById('host') as HTMLInputElement).value = profile.host || '';
  (document.getElementById('port') as HTMLInputElement).value = String(profile.port || 22);
  (document.getElementById('remote_a') as HTMLInputElement).value = profile.username || '';

  const authTypeEl = document.getElementById('authType') as HTMLSelectElement;
  authTypeEl.value = profile.authType || 'password';
  authTypeEl.dispatchEvent(new Event('change'));

  (document.getElementById('remote_c') as HTMLInputElement).value = '';
  const privateKeyEl = document.getElementById('privateKey') as HTMLTextAreaElement | null;
  const remotePpEl = document.getElementById('remote_pp') as HTMLInputElement | null;
  if (privateKeyEl) privateKeyEl.value = '';
  if (remotePpEl) remotePpEl.value = '';
  (document.getElementById('initialCommand') as HTMLInputElement).value = profile.initialCommand || '';

  const profileThemeEl = document.getElementById('profileTheme') as HTMLSelectElement | null;
  if (profileThemeEl) profileThemeEl.value = profile.theme ?? '';

  // Seed the color picker. If the profile has an explicit color we show it
  // and mark the input as "explicit" so save() preserves it. Otherwise we
  // mirror the theme accent and leave it non-explicit so editing the theme
  // auto-advances the color.
  const profileColorEl = document.getElementById('profileColor') as HTMLInputElement | null;
  if (profileColorEl) {
    const themeAccent = THEMES[(profile.theme as ThemeName | undefined) ?? 'dark'].app.accent;
    profileColorEl.value = profile.color ?? themeAccent;
    profileColorEl.dataset.explicit = profile.color ? '1' : '';
  }

  // Select the stored key in the dropdown if profile references one
  const keySelect = document.getElementById('selectedKeyId') as HTMLSelectElement | null;
  const manualKeyGroup = document.getElementById('manualKeyGroup');
  if (keySelect) {
    if (profile.keyVaultId) {
      keySelect.value = profile.keyVaultId;
      manualKeyGroup?.classList.add('hidden');
    } else {
      keySelect.value = '';
      manualKeyGroup?.classList.add('hidden');
    }
  }

  if (profile.vaultId && profile.hasVaultCreds) {
    if (!appState.vaultKey) {
      const unlocked = await ensureVaultKeyWithUI();
      if (!unlocked) {
        _toast('Vault locked — enter credentials manually');
        _navigateToConnect();
        return;
      }
    }
    const creds = await vaultLoad(profile.vaultId);
    if (creds) {
      if (creds.password) (document.getElementById('remote_c') as HTMLInputElement).value = creds.password as string;
      _toast('Credentials unlocked');
    } else {
      _toast('Vault locked — enter credentials manually');
    }
  } else if (!profile.hasVaultCreds) {
    _toast('Enter credentials — not saved on this browser.');
  }

  _updateFormSummary('Edit Profile');
  revealConnectForm();
  _navigateToConnect();
}

export async function connectFromProfile(idx: number): Promise<boolean> {
  const profile = getProfiles()[idx];
  if (!profile) return false;
  console.log(`[connect] connectFromProfile(${String(idx)}): ${profile.username}@${profile.host} vaultId=${profile.vaultId} hasVaultCreds=${String(!!profile.hasVaultCreds)} vaultKey=${String(!!appState.vaultKey)}`);

  const sshProfile: SSHProfile = {
    title: profile.title,
    host: profile.host,
    port: profile.port,
    username: profile.username,
    authType: profile.authType as 'password' | 'key',
    initialCommand: profile.initialCommand,
    ...(profile.theme ? { theme: profile.theme as ThemeName } : {}),
    ...(profile.color ? { color: profile.color } : {}),
  };

  if (profile.vaultId && profile.hasVaultCreds) {
    if (!appState.vaultKey) {
      const unlocked = await ensureVaultKeyWithUI();
      if (!unlocked) {
        _toast('Vault locked — enter credentials manually');
        _navigateToConnect();
        return false;
      }
    }
    const creds = await vaultLoad(profile.vaultId);
    if (creds) {
      if (creds.password) sshProfile.password = creds.password as string;
      if (creds.privateKey) sshProfile.privateKey = creds.privateKey as string;
      if (creds.passphrase) sshProfile.passphrase = creds.passphrase as string;
    } else {
      _toast('Vault locked — enter credentials manually');
      _navigateToConnect();
      return false;
    }
  }

  // Load key from stored key reference if profile uses one
  if (profile.keyVaultId && !sshProfile.privateKey) {
    if (!appState.vaultKey) {
      const unlocked = await ensureVaultKeyWithUI();
      if (!unlocked) {
        _toast('Vault locked — enter key manually');
        _navigateToConnect();
        return false;
      }
    }
    const keyCreds = await vaultLoad(profile.keyVaultId);
    if (keyCreds?.data) {
      sshProfile.privateKey = keyCreds.data as string;
      if (keyCreds.passphrase) {
        sshProfile.passphrase = keyCreds.passphrase as string;
      }
      sshProfile.keyVaultId = profile.keyVaultId;
    } else {
      _toast('Could not load stored key from vault.');
      _navigateToConnect();
      return false;
    }
  }

  if (!profile.hasVaultCreds && !profile.keyVaultId) {
    _toast('Enter credentials — not saved on this browser.');
    void loadProfileIntoForm(idx);
    return false;
  }

  await connect(sshProfile);
  // Theme is applied when the session reaches 'connected' state (#364)
  return true;
}

export function deleteProfile(idx: number): void {
  const profiles = getProfiles();
  const p = profiles[idx];
  if (p?.vaultId) vaultDelete(p.vaultId);
  profiles.splice(idx, 1);
  localStorage.setItem('sshProfiles', JSON.stringify(profiles));
  loadProfiles();
}

// ── Inline per-profile editing (#446) ────────────────────────────────────────

let _lastUndo: { idx: number; field: string; oldValue: string | number } | null = null;
let _undoTimer: ReturnType<typeof setTimeout> | null = null;

/** Close any open inline profile edit form. */
export function closeProfileEdit(): void {
  const existing = document.querySelector('.profile-edit-form');
  if (!existing) return;
  existing.remove();
  const editingItem = document.querySelector('.profile-editing');
  if (editingItem) editingItem.classList.remove('profile-editing');
}

/** Open an inline edit form inside the profile item at the given index. */
export function editProfile(idx: number): void {
  closeProfileEdit();

  const profiles = getProfiles();
  const profile = profiles[idx];
  if (!profile) return;

  const item = document.querySelector(`.profile-item[data-idx="${String(idx)}"]`);
  if (!item) return;

  item.classList.add('profile-editing');

  const form = document.createElement('div');
  form.className = 'profile-edit-form';

  const authIsKey = profile.authType === 'key';
  const pwGroupClass = authIsKey ? 'hidden' : '';
  const keyGroupClass = authIsKey ? '' : 'hidden';

  form.innerHTML = `
    <label for="editTitle-${String(idx)}">Name</label>
    <input type="text" id="editTitle-${String(idx)}" value="${escHtml(profile.title || '')}" data-field="title" placeholder="Auto: user@host" />
    <div class="form-row">
      <div class="form-field form-field-grow">
        <label for="editHost-${String(idx)}">Host</label>
        <input type="text" id="editHost-${String(idx)}" value="${escHtml(profile.host || '')}" data-field="host" inputmode="url" />
      </div>
      <div class="form-field form-field-port">
        <label for="editPort-${String(idx)}">Port</label>
        <input type="number" id="editPort-${String(idx)}" value="${String(profile.port || 22)}" data-field="port" min="1" max="65535" inputmode="numeric" />
      </div>
    </div>
    <label for="editUsername-${String(idx)}">User</label>
    <input type="text" id="editUsername-${String(idx)}" value="${escHtml(profile.username || '')}" data-field="username" autocapitalize="none" />
    <label for="editAuthType-${String(idx)}">Auth</label>
    <select id="editAuthType-${String(idx)}" data-field="authType">
      <option value="password"${!authIsKey ? ' selected' : ''}>Password</option>
      <option value="key"${authIsKey ? ' selected' : ''}>Private key</option>
    </select>
    <div class="edit-pw-group ${pwGroupClass}" id="editPwGroup-${String(idx)}">
      <label for="editPassword-${String(idx)}">Password</label>
      <input type="text" id="editPassword-${String(idx)}" data-field="password" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" placeholder="(vault-encrypted)" />
    </div>
    <div class="edit-key-group ${keyGroupClass}" id="editKeyGroup-${String(idx)}">
      <label>Key</label>
      <span class="text-dim">Managed via Stored Keys section</span>
    </div>
    <label for="editCommand-${String(idx)}">Command</label>
    <input type="text" id="editCommand-${String(idx)}" value="${escHtml(profile.initialCommand || '')}" data-field="initialCommand" autocomplete="off" autocorrect="off" autocapitalize="none" spellcheck="false" placeholder="Optional initial command" />
    <label for="editTheme-${String(idx)}">Session theme</label>
    <select id="editTheme-${String(idx)}" data-field="theme">
      <option value="">Use default</option>
      ${THEME_ORDER.map((name) => `<option value="${name}"${profile.theme === name ? ' selected' : ''}>${escHtml(THEMES[name].label)}</option>`).join('')}
    </select>
    <div class="profile-edit-actions">
      <button class="item-btn" data-action="close-edit">Done</button>
    </div>
  `;
  item.appendChild(form);
  form.scrollIntoView({ behavior: 'smooth', block: 'nearest' });

  // Auth type toggle: show/hide password vs key groups
  const authSelect = form.querySelector(`#editAuthType-${String(idx)}`) as HTMLSelectElement;
  authSelect.addEventListener('change', () => {
    const pwGroup = form.querySelector(`#editPwGroup-${String(idx)}`);
    const keyGroup = form.querySelector(`#editKeyGroup-${String(idx)}`);
    if (authSelect.value === 'key') {
      pwGroup?.classList.add('hidden');
      keyGroup?.classList.remove('hidden');
    } else {
      pwGroup?.classList.remove('hidden');
      keyGroup?.classList.add('hidden');
    }
    autoSaveField(idx, 'authType', authSelect.value);
  });

  // Auto-save on change/blur for all inputs and selects (except password — handled separately)
  const inputs = form.querySelectorAll<HTMLInputElement | HTMLSelectElement>('input[data-field], select[data-field]');
  for (const input of inputs) {
    const field = input.dataset.field;
    if (!field || field === 'authType' || field === 'password') continue;
    input.addEventListener('change', () => {
      const value = field === 'port' ? parseInt(input.value, 10) || 22 : input.value;
      autoSaveField(idx, field, value);
    });
  }

  // Password field: save to vault on blur, not to localStorage
  const pwInput = form.querySelector<HTMLInputElement>(`#editPassword-${String(idx)}`);
  if (pwInput) {
    pwInput.addEventListener('change', () => {
      void _savePasswordToVault(idx, pwInput.value);
    });
  }

  // Close button
  form.querySelector('[data-action="close-edit"]')?.addEventListener('click', () => {
    closeProfileEdit();
    loadProfiles();
  });
}

/** Auto-save a single profile field to localStorage and show undo toast. */
export function autoSaveField(idx: number, field: string, value: string | number): void {
  const profiles = getProfiles();
  const profile = profiles[idx];
  if (!profile) return;
  const oldValue = (profile as unknown as Record<string, string | number>)[field] ?? '';
  (profile as unknown as Record<string, string | number>)[field] = value;
  localStorage.setItem('sshProfiles', JSON.stringify(profiles));
  _showUndoToast(idx, field, oldValue);
}

/** Save password to vault (never to localStorage). */
async function _savePasswordToVault(idx: number, password: string): Promise<void> {
  const profiles = getProfiles();
  const profile = profiles[idx];
  if (!profile) return;

  if (!profile.vaultId) profile.vaultId = crypto.randomUUID();

  const hasVault = await ensureVaultKeyWithUI();
  if (!hasVault) {
    _toast('Password not saved — vault setup cancelled.');
    return;
  }

  const creds: Record<string, string> = {};
  if (password) creds.password = password;
  await vaultStore(profile.vaultId, creds);
  profile.hasVaultCreds = Object.keys(creds).length > 0;
  localStorage.setItem('sshProfiles', JSON.stringify(profiles));
  _toast('Password saved to vault.');
}

/** Show an undo toast with a clickable undo action. */
function _showUndoToast(idx: number, field: string, oldValue: string | number): void {
  _lastUndo = { idx, field, oldValue };
  if (_undoTimer) clearTimeout(_undoTimer);

  let el = document.getElementById('undoToast');
  if (!el) {
    el = document.createElement('div');
    el.id = 'undoToast';
    el.className = 'undo-toast';
    document.body.appendChild(el);
  }
  el.innerHTML = 'Saved. <button class="undo-action">Undo</button>';
  el.classList.add('show');

  const undoBtn = el.querySelector('.undo-action');
  const handler = (): void => {
    if (!_lastUndo) return;
    const profiles = getProfiles();
    const profile = profiles[_lastUndo.idx];
    if (profile) {
      (profile as unknown as Record<string, string | number>)[_lastUndo.field] = _lastUndo.oldValue;
      localStorage.setItem('sshProfiles', JSON.stringify(profiles));
      // Update the inline form field if still open
      const input = document.querySelector<HTMLInputElement>(`[data-field="${_lastUndo.field}"]`);
      if (input) input.value = String(_lastUndo.oldValue);
      _toast('Undone.');
    }
    _lastUndo = null;
    el.classList.remove('show');
  };
  undoBtn?.addEventListener('click', handler, { once: true });

  _undoTimer = setTimeout(() => {
    el.classList.remove('show');
    _lastUndo = null;
  }, 5000);
}

/** Populate the key dropdown in the connect form with current stored keys. */
export function populateKeyDropdown(): void {
  const select = document.getElementById('selectedKeyId') as HTMLSelectElement | null;
  if (!select) return;
  const currentValue = select.value;
  const keys = getKeys();
  select.innerHTML = '<option value="">Select a stored key...</option>'
    + keys.map(k => `<option value="${escHtml(k.vaultId)}">${escHtml(k.name)}</option>`).join('')
    + '<option value="manual">Paste key manually...</option>';
  // Restore previous selection if still valid
  if (currentValue && Array.from(select.options).some(o => o.value === currentValue)) {
    select.value = currentValue;
  }
}

// Key storage

interface StoredKey {
  name: string;
  vaultId: string;
  created: string;
}

export function getKeys(): StoredKey[] {
  return JSON.parse(localStorage.getItem('sshKeys') || '[]') as StoredKey[];
}

export function loadKeys(): void {
  const keys = getKeys();
  const list = document.getElementById('keyList');
  if (!list) return;

  if (!keys.length) {
    list.innerHTML = '<p class="empty-hint">No keys stored.</p>';
    return;
  }

  list.innerHTML = keys.map((k, i) => `
    <div class="key-item" data-key-idx="${String(i)}">
      <span class="key-name">${escHtml(k.name)}</span>
      <div class="key-info-row">
        <span class="key-created">Added ${new Date(k.created).toLocaleDateString()}</span>
        <span class="key-passphrase-badge" data-vault-id="${escHtml(k.vaultId)}"></span>
      </div>
      <div class="item-actions">
        <button class="item-btn" data-action="edit" data-idx="${String(i)}">Edit</button>
        <button class="item-btn danger" data-action="delete" data-idx="${String(i)}">Delete</button>
      </div>
    </div>
  `).join('');

  // Async: check vault for passphrase badges
  void _updatePassphraseBadges(keys);
}

async function _updatePassphraseBadges(keys: StoredKey[]): Promise<void> {
  for (const k of keys) {
    try {
      const record = await vaultLoad(k.vaultId);
      const badge = document.querySelector(`.key-passphrase-badge[data-vault-id="${CSS.escape(k.vaultId)}"]`);
      if (badge && record && typeof record.passphrase === 'string' && record.passphrase.length > 0) {
        badge.textContent = '\u{1F512} Passphrase set';
      }
    } catch { /* vault locked or missing — skip badge */ }
  }
}

export async function editKey(idx: number): Promise<void> {
  const keys = getKeys();
  const key = keys[idx];
  if (!key) return;

  const item = document.querySelector(`.key-item[data-key-idx="${String(idx)}"]`);
  if (!item) return;

  // Don't open a second edit form
  if (item.querySelector('.key-edit-form')) return;

  // Hide action buttons while editing
  const actions = item.querySelector<HTMLElement>('.item-actions');
  if (actions) actions.style.display = 'none';

  // Load existing passphrase from vault
  let existingPassphrase = '';
  try {
    const record = await vaultLoad(key.vaultId);
    if (record && typeof record.passphrase === 'string') {
      existingPassphrase = record.passphrase;
    }
  } catch { /* vault locked — leave empty */ }

  const form = document.createElement('div');
  form.className = 'key-edit-form';
  form.innerHTML = `
    <label for="editKeyName-${String(idx)}">Name</label>
    <input type="text" id="editKeyName-${String(idx)}" value="${escHtml(key.name)}" />
    <label for="editKeyPass-${String(idx)}">Passphrase</label>
    <input type="password" id="editKeyPass-${String(idx)}" value="${escHtml(existingPassphrase)}" placeholder="(none)" autocomplete="off" />
    <div class="key-edit-actions">
      <button class="item-btn accent" data-action="save-edit" data-idx="${String(idx)}">Save</button>
      <button class="item-btn" data-action="cancel-edit" data-idx="${String(idx)}">Cancel</button>
    </div>
  `;
  item.appendChild(form);
  form.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
}

export async function saveKeyEdit(idx: number): Promise<void> {
  const nameInput = document.getElementById(`editKeyName-${String(idx)}`) as HTMLInputElement | null;
  const passInput = document.getElementById(`editKeyPass-${String(idx)}`) as HTMLInputElement | null;
  if (!nameInput || !passInput) return;

  const newName = nameInput.value.trim();
  if (!newName) { _toast('Key name cannot be empty.'); return; }

  const keys = getKeys();
  const key = keys[idx];
  if (!key) return;

  // Update name
  key.name = newName;
  localStorage.setItem('sshKeys', JSON.stringify(keys));

  // Update passphrase in vault
  try {
    const record = await vaultLoad(key.vaultId);
    if (record) {
      record.passphrase = passInput.value;
      await vaultStore(key.vaultId, record);
    }
  } catch { _toast('Could not save passphrase — vault may be locked.'); }

  loadKeys();
  populateKeyDropdown();
  _toast(`Key "${key.name}" updated.`);
}

export function cancelKeyEdit(idx: number): void {
  const item = document.querySelector(`.key-item[data-key-idx="${String(idx)}"]`);
  if (!item) return;

  const form = item.querySelector('.key-edit-form');
  if (form) form.remove();

  const actions = item.querySelector<HTMLElement>('.item-actions');
  if (actions) actions.style.display = '';
}

export async function importKey(name: string, data: string): Promise<boolean> {
  if (!name || !data) { _toast('Name and key data are required.'); return false; }
  if (!data.includes('PRIVATE KEY')) { _toast('Does not look like a PEM private key.'); return false; }

  const hasVault = await ensureVaultKeyWithUI();
  if (!hasVault) { _toast('Key not saved — vault setup cancelled.'); return false; }

  const vaultId = _generateId();
  await vaultStore(vaultId, { data });

  const keys = getKeys();
  keys.push({ name, vaultId, created: new Date().toISOString() });
  localStorage.setItem('sshKeys', JSON.stringify(keys));
  loadKeys();
  populateKeyDropdown();
  _toast(`Key "${name}" saved.`);
  return true;
}

export function renameKey(idx: number, newName: string): void {
  if (!newName.trim()) { _toast('Key name cannot be empty.'); return; }
  const keys = getKeys();
  const key = keys[idx];
  if (!key) return;
  key.name = newName.trim();
  localStorage.setItem('sshKeys', JSON.stringify(keys));
  loadKeys();
  populateKeyDropdown();
  _toast(`Key renamed to "${key.name}".`);
}

export function deleteKey(idx: number): void {
  const keys = getKeys();
  const key = keys[idx];
  if (key?.vaultId) vaultDelete(key.vaultId);
  keys.splice(idx, 1);
  localStorage.setItem('sshKeys', JSON.stringify(keys));
  loadKeys();
  populateKeyDropdown();
}

// ── Export / Import (#419) ─────────────────────────────────────────────────

/** Safe metadata fields included in export. Everything else is stripped. */
const EXPORT_FIELDS = ['title', 'host', 'port', 'username', 'authType'] as const;

/** Serialize saved profiles to JSON string containing ONLY non-sensitive metadata. */
export function exportProfilesJSON(): string {
  const profiles = getProfiles();
  const safe = profiles.map((p) => {
    const out: Record<string, unknown> = {};
    for (const field of EXPORT_FIELDS) {
      out[field] = p[field];
    }
    return out;
  });
  return JSON.stringify(safe, null, 2);
}

/** Trigger a browser download of exported profiles. */
export function downloadProfilesExport(): void {
  const json = exportProfilesJSON();
  const blob = new Blob([json], { type: 'application/json' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = 'mobissh-profiles.json';
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
}

interface ImportResult {
  added: number;
  skipped: number;
  errors: string[];
}

/** Parse and import profiles from JSON string. Deduplicates by host+port+username. */
export function importProfilesFromJSON(json: string): ImportResult {
  const result: ImportResult = { added: 0, skipped: 0, errors: [] };

  let parsed: unknown;
  try {
    parsed = JSON.parse(json);
  } catch {
    result.errors.push('Invalid JSON format');
    return result;
  }

  if (!Array.isArray(parsed)) {
    result.errors.push('Invalid format: expected an array of profiles');
    return result;
  }

  const existing = getProfiles();

  for (const entry of parsed) {
    if (typeof entry !== 'object' || entry === null) {
      result.errors.push('Invalid entry: not an object');
      continue;
    }
    const rec = entry as Record<string, unknown>;

    // Validate required fields
    if (!rec.host || typeof rec.host !== 'string') {
      result.errors.push('Invalid entry: missing or invalid host');
      continue;
    }
    if (!rec.username || typeof rec.username !== 'string') {
      result.errors.push('Invalid entry: missing or invalid username');
      continue;
    }

    const port = typeof rec.port === 'number' ? rec.port : 22;
    const host = rec.host;
    const username = rec.username;

    // Dedup: skip if host+port+username already exists
    const isDup = existing.some(
      (p) => p.host === host && (p.port || 22) === port && p.username === username
    );
    if (isDup) {
      result.skipped++;
      continue;
    }

    // Build a clean profile with only safe fields + fresh vaultId
    const imported: StoredProfile = {
      title: typeof rec.title === 'string' ? rec.title : `${username}@${host}`,
      host,
      port,
      username,
      authType: rec.authType === 'key' ? 'key' : 'password',
      initialCommand: '',
      vaultId: _generateId(),
    };

    existing.push(imported);
    result.added++;
  }

  localStorage.setItem('sshProfiles', JSON.stringify(existing));
  loadProfiles();
  return result;
}

/** Open a file picker and import profiles from the selected JSON file. */
export function triggerProfileImport(): void {
  const input = document.createElement('input');
  input.type = 'file';
  input.accept = '.json,application/json';
  input.addEventListener('change', () => {
    const file = input.files?.[0];
    if (!file) return;
    const reader = new FileReader();
    reader.onload = () => {
      const text = reader.result as string;
      const result = importProfilesFromJSON(text);
      if (result.errors.length > 0) {
        _toast(`Import: ${String(result.added)} added, ${String(result.skipped)} skipped, ${String(result.errors.length)} errors`);
      } else {
        _toast(`Imported ${String(result.added)} profile${result.added !== 1 ? 's' : ''}${result.skipped > 0 ? `, ${String(result.skipped)} skipped (duplicates)` : ''}`);
      }
    };
    reader.readAsText(file);
  });
  input.click();
}
