/**
 * modules/vault.js — Credential vault (AES-GCM encrypted at rest)
 *
 * The vault key is derived from one of two sources:
 *   1. PasswordCredential (Chrome/Android) — random 32-byte key in credential store
 *   2. WebAuthn PRF (#14, Safari 18+/iOS 18+) — key derived from passkey + biometric
 * If neither is available, credentials are not saved (never stored in plaintext).
 */

import type { VaultMethod } from './types.js';
import { appState } from './state.js';

const VAULT_CRED_ID = 'ssh-pwa-vault';

function _b64(bytes: Uint8Array): string {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}
function _bytes(b64: string): Uint8Array<ArrayBuffer> {
  const raw = atob(b64);
  const arr = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) arr[i] = raw.charCodeAt(i);
  return arr;
}

// Detect which vault key derivation method this browser supports.
// PasswordCredential (Chrome/Android) > WebAuthn PRF (Safari 18+/iOS 18+) > null
function _detectVaultMethod(): VaultMethod {
  if (typeof window.PasswordCredential !== 'undefined' && 'credentials' in navigator) return 'passwordcred';
  if (typeof window.PublicKeyCredential !== 'undefined' && 'credentials' in navigator) return 'webauthn-prf';
  return null;
}

// WebAuthn PRF helpers (#14)
// On browsers without PasswordCredential (iOS Safari), derive the vault AES key
// from a passkey via the WebAuthn PRF extension. Requires iOS 18+ / Safari 18+.

function _webauthnHasRegistration(): boolean {
  return !!(localStorage.getItem('webauthnCredId') && localStorage.getItem('webauthnPrfSalt'));
}

async function _webauthnRegister(): Promise<boolean> {
  const salt = crypto.getRandomValues(new Uint8Array(32));
  const userId = crypto.getRandomValues(new Uint8Array(16));
  try {
    const credential = await navigator.credentials.create({
      publicKey: {
        rp: { name: 'MobiSSH', id: location.hostname },
        user: { id: userId, name: 'MobiSSH Vault', displayName: 'MobiSSH Vault' },
        challenge: crypto.getRandomValues(new Uint8Array(32)),
        pubKeyCredParams: [
          { type: 'public-key', alg: -7 },
          { type: 'public-key', alg: -257 },
        ],
        authenticatorSelection: {
          authenticatorAttachment: 'platform',
          residentKey: 'preferred',
          userVerification: 'required',
        },
        extensions: { prf: {} },
      },
    }) as PublicKeyCredential | null;
    if (!credential) return false;
    const ext = credential.getClientExtensionResults();
    if (!ext.prf?.enabled) return false;
    localStorage.setItem('webauthnCredId', _b64(new Uint8Array(credential.rawId)));
    localStorage.setItem('webauthnPrfSalt', _b64(salt));
    return await _webauthnDerive('required');
  } catch { return false; }
}

async function _webauthnDerive(mediation: CredentialMediationRequirement): Promise<boolean> {
  const credIdB64 = localStorage.getItem('webauthnCredId');
  const saltB64 = localStorage.getItem('webauthnPrfSalt');
  if (!credIdB64 || !saltB64) return false;
  const credId = _bytes(credIdB64);
  const salt = _bytes(saltB64);
  try {
    const assertion = await navigator.credentials.get({
      publicKey: {
        challenge: crypto.getRandomValues(new Uint8Array(32)),
        rpId: location.hostname,
        allowCredentials: [{ type: 'public-key', id: credId.buffer }],
        userVerification: 'required',
        extensions: { prf: { eval: { first: salt.buffer } } },
      },
      mediation,
    }) as PublicKeyCredential | null;
    if (!assertion) return false;
    const ext = assertion.getClientExtensionResults();
    if (!ext.prf?.results?.first) return false;
    // eslint-disable-next-line @typescript-eslint/no-unnecessary-type-assertion -- DOM lib types `first` as BufferSource, not ArrayBuffer
    const keyBytes = new Uint8Array(ext.prf.results.first as ArrayBuffer);
    appState.vaultKey = await crypto.subtle.importKey(
      'raw', keyBytes, { name: 'AES-GCM' }, false, ['encrypt', 'decrypt']
    );
    return true;
  } catch { return false; }
}

// Vault lifecycle

export async function initVault(): Promise<void> {
  appState.vaultMethod = _detectVaultMethod();
  if (!appState.vaultMethod) return;
  const vault = JSON.parse(localStorage.getItem('sshVault') || '{}') as Record<string, unknown>;
  if (!Object.keys(vault).length) return;
  await tryUnlockVault('silent');
}

export async function tryUnlockVault(mediation: CredentialMediationRequirement): Promise<boolean> {
  if (appState.vaultMethod === 'passwordcred') {
    try {
      const cred = await navigator.credentials.get({
        password: true,
        mediation,
      }) as PasswordCredential | null;
      if (cred?.password) {
        const keyBytes = _bytes(cred.password);
        appState.vaultKey = await crypto.subtle.importKey(
          'raw', keyBytes, { name: 'AES-GCM' }, false, ['encrypt', 'decrypt']
        );
        return true;
      }
    } catch { /* denied or unavailable */ }
    return false;
  }
  if (appState.vaultMethod === 'webauthn-prf') {
    if (!_webauthnHasRegistration()) return false;
    return await _webauthnDerive(mediation);
  }
  return false;
}

export async function ensureVaultKey(): Promise<boolean> {
  if (appState.vaultKey) return true;
  if (appState.vaultMethod === 'passwordcred') {
    try {
      const keyBytes = crypto.getRandomValues(new Uint8Array(32));
      const rawKey = _b64(keyBytes);
      const cred = new PasswordCredential({ id: VAULT_CRED_ID, password: rawKey, name: 'SSH PWA' });
      await navigator.credentials.store(cred);
      appState.vaultKey = await crypto.subtle.importKey(
        'raw', keyBytes, { name: 'AES-GCM' }, false, ['encrypt', 'decrypt']
      );
      return true;
    } catch { return false; }
  }
  if (appState.vaultMethod === 'webauthn-prf') {
    if (_webauthnHasRegistration()) return await _webauthnDerive('required');
    return await _webauthnRegister();
  }
  return false;
}

interface VaultEntry {
  iv: string;
  ct: string;
}

export async function vaultStore(vaultId: string, data: Record<string, unknown>): Promise<void> {
  if (!appState.vaultKey) return;
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv }, appState.vaultKey,
    new TextEncoder().encode(JSON.stringify(data))
  );
  const vault = JSON.parse(localStorage.getItem('sshVault') || '{}') as Record<string, VaultEntry>;
  vault[vaultId] = { iv: _b64(iv), ct: _b64(new Uint8Array(ct)) };
  localStorage.setItem('sshVault', JSON.stringify(vault));
}

export async function vaultLoad(vaultId: string): Promise<Record<string, unknown> | null> {
  if (!appState.vaultKey) return null;
  const vault = JSON.parse(localStorage.getItem('sshVault') || '{}') as Record<string, VaultEntry | undefined>;
  const entry = vault[vaultId];
  if (!entry) return null;
  try {
    const plain = await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: _bytes(entry.iv) }, appState.vaultKey, _bytes(entry.ct)
    );
    return JSON.parse(new TextDecoder().decode(plain)) as Record<string, unknown>;
  } catch { return null; }
}

export function vaultDelete(vaultId: string): void {
  const vault = JSON.parse(localStorage.getItem('sshVault') || '{}') as Record<string, unknown>;
  const { [vaultId]: _, ...rest } = vault;
  localStorage.setItem('sshVault', JSON.stringify(rest));
}
