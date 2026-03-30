/**
 * modules/profiles.ts — Profile & key storage
 *
 * Manages saved SSH connection profiles and imported private keys.
 * Profile metadata is stored in localStorage; credentials are encrypted
 * in the vault (never plaintext).
 */

import type { ProfilesDeps, SSHProfile, ThemeName } from './types.js';
import { appState, isSessionConnected } from './state.js';
import { escHtml } from './constants.js';
import { vaultStore, vaultLoad, vaultDelete } from './vault.js';
import { ensureVaultKeyWithUI } from './vault-ui.js';
import { connect } from './connection.js';

export { escHtml };

let _toast = (_msg: string): void => {};
let _navigateToConnect = (): void => {};

export function initProfiles({ toast, navigateToConnect }: ProfilesDeps): void {
  _toast = toast;
  _navigateToConnect = navigateToConnect;
}

// Profile storage

interface StoredProfile {
  name: string;
  host: string;
  port: number;
  username: string;
  authType: string;
  initialCommand: string;
  vaultId: string;
  hasVaultCreds?: boolean;
  keyVaultId?: string;
  theme?: string;
}

export function getProfiles(): StoredProfile[] {
  return JSON.parse(localStorage.getItem('sshProfiles') || '[]') as StoredProfile[];
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

  const saved: StoredProfile = {
    name: profile.name,
    host: profile.host,
    port: profile.port,
    username: profile.username,
    authType: profile.authType,
    initialCommand: profile.initialCommand ?? '',
    vaultId,
    ...(profileTheme ? { theme: profileTheme } : {}),
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

  const formSection = document.getElementById('connect-form-section');
  const newConnBtn = document.getElementById('newConnBtn') as HTMLButtonElement | null;

  // Render active sessions section (#306)
  const allSessions = Array.from(appState.sessions.values()).filter((s) => s.profile);
  if (sessionList) {
    if (allSessions.length > 0) {
      const hasDropped = allSessions.some((s) => !isSessionConnected(s));
      const reconnectAllBtn = hasDropped
        ? '<button class="item-btn accent reconnect-all-btn" data-action="reconnect-all">Reconnect all</button>'
        : '';
      sessionList.innerHTML = `<h3 class="section-label">Active Sessions</h3>`
        + allSessions.map((s) => {
          const stateClass = `session-state-${s.state}`;
          const dotColor = isSessionConnected(s) ? 'dot-connected' : s.state === 'reconnecting' || s.state === 'connecting' ? 'dot-connecting' : 'dot-dropped';
          const label = s.profile ? `${escHtml(s.profile.username)}@${escHtml(s.profile.host)}` : escHtml(s.id);
          const actionBtn = isSessionConnected(s)
            ? `<button class="item-btn accent" data-action="switch" data-session-id="${escHtml(s.id)}">Switch</button>`
            : `<button class="item-btn accent" data-action="reconnect" data-session-id="${escHtml(s.id)}">Reconnect</button>`;
          return `<div class="active-session-item ${stateClass}" data-session-id="${escHtml(s.id)}">
            <span class="session-dot ${dotColor}"></span>
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

  if (!profiles.length) {
    list.innerHTML = '<p class="empty-hint">No saved profiles yet.</p>';
    formSection?.classList.remove('connect-form-hidden');
    if (newConnBtn) newConnBtn.hidden = true;
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
      return `<div class="profile-item${connClass}" data-idx="${String(i)}">
        <span class="profile-name">${escHtml(p.name)}</span>
        <span class="profile-host">${escHtml(p.username)}@${escHtml(p.host)}:${String(p.port || 22)}</span>
        <div class="item-actions">
          <button class="item-btn" data-action="edit" data-idx="${String(i)}">Edit</button>
          <button class="${connectBtnClass}" data-action="connect" data-idx="${String(i)}">${connectBtnText}</button>
          <button class="item-btn danger" data-action="delete" data-idx="${String(i)}">Delete</button>
        </div>
      </div>`;
    }).join('');

  formSection?.classList.add('connect-form-hidden');
  if (newConnBtn) newConnBtn.hidden = false;
}

/** Reveal the connect form section. */
export function revealConnectForm(): void {
  document.getElementById('connect-form-section')?.classList.remove('connect-form-hidden');
  const newConnBtn = document.getElementById('newConnBtn') as HTMLButtonElement | null;
  if (newConnBtn) newConnBtn.hidden = true;
}

/** Reset form for a brand-new connection and reveal it. */
export function newConnection(): void {
  const form = document.getElementById('connectForm') as HTMLFormElement | null;
  if (form) form.reset();
  (document.getElementById('port') as HTMLInputElement).value = '22';
  const keySelect = document.getElementById('selectedKeyId') as HTMLSelectElement | null;
  if (keySelect) keySelect.value = '';
  document.getElementById('manualKeyGroup')?.classList.add('hidden');
  revealConnectForm();
  (document.getElementById('host') as HTMLInputElement).focus();
}

export async function loadProfileIntoForm(idx: number): Promise<void> {
  const profile = getProfiles()[idx];
  if (!profile) return;

  (document.getElementById('profileName') as HTMLInputElement).value = profile.name || '';
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

  revealConnectForm();
  _navigateToConnect();
}

export async function connectFromProfile(idx: number): Promise<boolean> {
  const profile = getProfiles()[idx];
  if (!profile) return false;

  const sshProfile: SSHProfile = {
    name: profile.name,
    host: profile.host,
    port: profile.port,
    username: profile.username,
    authType: profile.authType as 'password' | 'key',
    initialCommand: profile.initialCommand,
    ...(profile.theme ? { theme: profile.theme as ThemeName } : {}),
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
    <div class="key-item">
      <span class="key-name">${escHtml(k.name)}</span>
      <span class="key-created">Added ${new Date(k.created).toLocaleDateString()}</span>
      <div class="item-actions">
        <button class="item-btn" data-action="rename" data-idx="${String(i)}">Rename</button>
        <button class="item-btn" data-action="use" data-idx="${String(i)}">Use in form</button>
        <button class="item-btn danger" data-action="delete" data-idx="${String(i)}">Delete</button>
      </div>
    </div>
  `).join('');
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

export function useKey(idx: number): void {
  const key = getKeys()[idx];
  if (!key) return;
  (document.getElementById('authType') as HTMLSelectElement).value = 'key';
  (document.getElementById('authType') as HTMLSelectElement).dispatchEvent(new Event('change'));
  const keySelect = document.getElementById('selectedKeyId') as HTMLSelectElement | null;
  if (keySelect) {
    keySelect.value = key.vaultId;
  }
  _toast(`Key "${key.name}" selected in form.`);
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
