/**
 * modules/profiles.ts — Profile & key storage
 *
 * Manages saved SSH connection profiles and imported private keys.
 * Profile metadata is stored in localStorage; credentials are encrypted
 * in the vault (never plaintext).
 */
import { appState } from './state.js';
import { escHtml } from './constants.js';
import { vaultStore, vaultLoad, vaultDelete } from './vault.js';
import { ensureVaultKeyWithUI } from './vault-ui.js';
export { escHtml };
let _toast = (_msg) => { };
let _navigateToConnect = () => { };
export function initProfiles({ toast, navigateToConnect }) {
    _toast = toast;
    _navigateToConnect = navigateToConnect;
}
export function getProfiles() {
    return JSON.parse(localStorage.getItem('sshProfiles') || '[]');
}
function _generateId() {
    return crypto.randomUUID();
}
export async function saveProfile(profile) {
    const profiles = getProfiles();
    const existingIdx = profiles.findIndex((p) => p.host === profile.host &&
        String(p.port || 22) === String(profile.port || 22) &&
        p.username === profile.username);
    const vaultId = existingIdx >= 0
        ? (profiles[existingIdx]?.vaultId ?? _generateId())
        : _generateId();
    const saved = {
        name: profile.name,
        host: profile.host,
        port: profile.port,
        username: profile.username,
        authType: profile.authType,
        initialCommand: profile.initialCommand ?? '',
        vaultId,
    };
    const creds = {};
    if (profile.password)
        creds.password = profile.password;
    if (profile.privateKey)
        creds.privateKey = profile.privateKey;
    if (profile.passphrase)
        creds.passphrase = profile.passphrase;
    const hasVault = await ensureVaultKeyWithUI();
    if (hasVault && Object.keys(creds).length) {
        await vaultStore(vaultId, creds);
        saved.hasVaultCreds = true;
    }
    else if (!hasVault && Object.keys(creds).length) {
        _toast('Credentials not saved — vault setup cancelled.');
    }
    if (existingIdx >= 0) {
        profiles[existingIdx] = saved;
    }
    else {
        profiles.push(saved);
    }
    localStorage.setItem('sshProfiles', JSON.stringify(profiles));
    loadProfiles();
}
export function loadProfiles() {
    const profiles = getProfiles();
    const list = document.getElementById('profileList');
    if (!list)
        return;
    if (!profiles.length) {
        list.innerHTML = '<p class="empty-hint">No saved profiles yet.</p>';
        return;
    }
    list.innerHTML = profiles.map((p, i) => `
    <div class="profile-item" data-idx="${String(i)}">
      <span class="profile-name">${escHtml(p.name)}${p.hasVaultCreds ? ' <span class="vault-badge">saved</span>' : ''}</span>
      <span class="profile-host">${escHtml(p.username)}@${escHtml(p.host)}:${String(p.port || 22)}</span>
      <div class="item-actions">
        <button class="item-btn" data-action="edit" data-idx="${String(i)}">✎ Edit</button>
        <button class="item-btn danger" data-action="delete" data-idx="${String(i)}">Delete</button>
      </div>
    </div>
  `).join('');
}
export async function loadProfileIntoForm(idx) {
    const profile = getProfiles()[idx];
    if (!profile)
        return;
    document.getElementById('profileName').value = profile.name || '';
    document.getElementById('host').value = profile.host || '';
    document.getElementById('port').value = String(profile.port || 22);
    document.getElementById('remote_a').value = profile.username || '';
    const authTypeEl = document.getElementById('authType');
    authTypeEl.value = profile.authType || 'password';
    authTypeEl.dispatchEvent(new Event('change'));
    document.getElementById('remote_c').value = '';
    document.getElementById('privateKey').value = '';
    document.getElementById('remote_pp').value = '';
    document.getElementById('initialCommand').value = profile.initialCommand || '';
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
            if (creds.password)
                document.getElementById('remote_c').value = creds.password;
            if (creds.privateKey)
                document.getElementById('privateKey').value = creds.privateKey;
            if (creds.passphrase)
                document.getElementById('remote_pp').value = creds.passphrase;
            _toast('Credentials unlocked');
        }
        else {
            _toast('Vault locked — enter credentials manually');
        }
    }
    else if (!profile.hasVaultCreds) {
        _toast('Enter credentials — not saved on this browser.');
    }
    _navigateToConnect();
}
export function deleteProfile(idx) {
    const profiles = getProfiles();
    const p = profiles[idx];
    if (p?.vaultId)
        vaultDelete(p.vaultId);
    profiles.splice(idx, 1);
    localStorage.setItem('sshProfiles', JSON.stringify(profiles));
    loadProfiles();
}
export function getKeys() {
    return JSON.parse(localStorage.getItem('sshKeys') || '[]');
}
export function loadKeys() {
    const keys = getKeys();
    const list = document.getElementById('keyList');
    if (!list)
        return;
    if (!keys.length) {
        list.innerHTML = '<p class="empty-hint">No keys stored.</p>';
        return;
    }
    list.innerHTML = keys.map((k, i) => `
    <div class="key-item">
      <span class="key-name">${escHtml(k.name)}</span>
      <span class="key-created">Added ${new Date(k.created).toLocaleDateString()}</span>
      <div class="item-actions">
        <button class="item-btn" data-action="use" data-idx="${String(i)}">Use in form</button>
        <button class="item-btn danger" data-action="delete" data-idx="${String(i)}">Delete</button>
      </div>
    </div>
  `).join('');
}
export async function importKey(name, data) {
    if (!name || !data) {
        _toast('Name and key data are required.');
        return false;
    }
    if (!data.includes('PRIVATE KEY')) {
        _toast('Does not look like a PEM private key.');
        return false;
    }
    const hasVault = await ensureVaultKeyWithUI();
    if (!hasVault) {
        _toast('Key not saved — vault setup cancelled.');
        return false;
    }
    const vaultId = _generateId();
    await vaultStore(vaultId, { data });
    const keys = getKeys();
    keys.push({ name, vaultId, created: new Date().toISOString() });
    localStorage.setItem('sshKeys', JSON.stringify(keys));
    loadKeys();
    _toast(`Key "${name}" saved.`);
    return true;
}
export async function useKey(idx) {
    const key = getKeys()[idx];
    if (!key)
        return;
    if (!appState.vaultKey) {
        const unlocked = await ensureVaultKeyWithUI();
        if (!unlocked) {
            _toast('Vault locked — enter key manually.');
            return;
        }
    }
    const creds = key.vaultId ? await vaultLoad(key.vaultId) : null;
    if (!creds) {
        _toast('Could not load key from vault.');
        return;
    }
    document.getElementById('authType').value = 'key';
    document.getElementById('authType').dispatchEvent(new Event('change'));
    document.getElementById('privateKey').value = creds.data;
    _toast(`Key "${key.name}" loaded into form.`);
}
export function deleteKey(idx) {
    const keys = getKeys();
    const key = keys[idx];
    if (key?.vaultId)
        vaultDelete(key.vaultId);
    keys.splice(idx, 1);
    localStorage.setItem('sshKeys', JSON.stringify(keys));
    loadKeys();
}
//# sourceMappingURL=profiles.js.map