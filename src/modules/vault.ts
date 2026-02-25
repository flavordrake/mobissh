/**
 * modules/vault.ts — Credential vault (DEK+KEK architecture)
 *
 * The vault encrypts all credentials with a random 256-bit Data Encryption Key (DEK).
 * The DEK is never stored in plaintext. It is wrapped by one or two Key Encryption Keys:
 *
 *   Path A (always): Master password -> PBKDF2-SHA256 (600k iterations) -> KEK_pw -> wraps DEK
 *   Path B (optional): WebAuthn PRF -> HKDF-SHA256 -> KEK_bio -> wraps DEK
 *
 * PasswordCredential is no longer used (fixes #98 autofill interference).
 */

import type { VaultMeta, WrappedKey } from './types.js';
import { appState } from './state.js';

const PBKDF2_ITERATIONS = 600_000;
const VAULT_IDLE_MS = 5 * 60 * 1000; // 5 minutes
const VAULT_META_KEY = 'vaultMeta';
const VAULT_DATA_KEY = 'sshVault';

// base64 helpers
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

// Crypto primitives

async function _deriveKekFromPassword(password: string, salt: Uint8Array): Promise<CryptoKey> {
  const keyMaterial = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(password), 'PBKDF2', false, ['deriveBits']
  );
  const bits = await crypto.subtle.deriveBits(
    { name: 'PBKDF2', salt: salt.buffer as ArrayBuffer, iterations: PBKDF2_ITERATIONS, hash: 'SHA-256' },
    keyMaterial, 256
  );
  return crypto.subtle.importKey('raw', bits, { name: 'AES-GCM' }, false, ['wrapKey', 'unwrapKey']);
}

async function _wrapDek(kek: CryptoKey, dek: CryptoKey): Promise<WrappedKey> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = await crypto.subtle.wrapKey('raw', dek, kek, { name: 'AES-GCM', iv });
  return { iv: _b64(iv), ct: _b64(new Uint8Array(ct)) };
}

async function _unwrapDek(kek: CryptoKey, wrapped: WrappedKey): Promise<CryptoKey> {
  return crypto.subtle.unwrapKey(
    'raw', _bytes(wrapped.ct), kek,
    { name: 'AES-GCM', iv: _bytes(wrapped.iv) },
    { name: 'AES-GCM' }, true, ['encrypt', 'decrypt']
  );
}

function _generateDek(): Promise<CryptoKey> {
  return crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, true, ['encrypt', 'decrypt']);
}

// Vault metadata persistence

function _loadMeta(): VaultMeta | null {
  const raw = localStorage.getItem(VAULT_META_KEY);
  if (!raw) return null;
  return JSON.parse(raw) as VaultMeta;
}

function _saveMeta(meta: VaultMeta): void {
  localStorage.setItem(VAULT_META_KEY, JSON.stringify(meta));
}

// Idle timeout

function _resetIdleTimer(): void {
  if (appState.vaultIdleTimer) clearTimeout(appState.vaultIdleTimer);
  if (!appState.vaultKey) return;
  appState.vaultIdleTimer = setTimeout(() => {
    lockVault();
  }, VAULT_IDLE_MS);
}

export function lockVault(): void {
  appState.vaultKey = null;
  if (appState.vaultIdleTimer) {
    clearTimeout(appState.vaultIdleTimer);
    appState.vaultIdleTimer = null;
  }
}

// WebAuthn PRF helpers

function _hasBioEnrollment(): boolean {
  const meta = _loadMeta();
  return !!(meta?.dekBio && localStorage.getItem('webauthnCredId') && localStorage.getItem('webauthnPrfSalt'));
}

export function prfAvailable(): boolean {
  return typeof window.PublicKeyCredential !== 'undefined' && 'credentials' in navigator;
}

async function _webauthnRegisterAndWrapDek(dek: CryptoKey): Promise<boolean> {
  const prfSalt = crypto.getRandomValues(new Uint8Array(32));
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
    localStorage.setItem('webauthnPrfSalt', _b64(prfSalt));

    // Derive KEK_bio from PRF and wrap the DEK
    const kekBio = await _deriveKekFromPrf(prfSalt, credential.rawId);
    if (!kekBio) return false;
    const dekBio = await _wrapDek(kekBio, dek);
    const meta = _loadMeta();
    if (!meta) return false;
    meta.dekBio = dekBio;
    _saveMeta(meta);
    appState.vaultMethod = 'master-pw+bio';
    return true;
  } catch { return false; }
}

async function _deriveKekFromPrf(
  prfSalt: Uint8Array,
  credIdRaw: ArrayBuffer,
  mediation: CredentialMediationRequirement = 'required'
): Promise<CryptoKey | null> {
  const credId = new Uint8Array(credIdRaw);

  try {
    const assertion = await navigator.credentials.get({
      publicKey: {
        challenge: crypto.getRandomValues(new Uint8Array(32)),
        rpId: location.hostname,
        allowCredentials: [{ type: 'public-key', id: credId.buffer }],
        userVerification: 'required',
        extensions: { prf: { eval: { first: prfSalt.buffer as ArrayBuffer } } },
      },
      mediation,
    }) as PublicKeyCredential | null;
    if (!assertion) return null;
    const ext = assertion.getClientExtensionResults();
    if (!ext.prf?.results?.first) return null;

    // HKDF domain separation (per bot research recommendation)
    // eslint-disable-next-line @typescript-eslint/no-unnecessary-type-assertion -- DOM lib types `first` as BufferSource, not ArrayBuffer
    const prfOutput = new Uint8Array(ext.prf.results.first as ArrayBuffer);
    const hkdfKey = await crypto.subtle.importKey('raw', prfOutput, 'HKDF', false, ['deriveBits']);
    const bits = await crypto.subtle.deriveBits(
      { name: 'HKDF', hash: 'SHA-256', salt: new Uint8Array(32), info: new TextEncoder().encode('MobiSSH Vault KEK') },
      hkdfKey, 256
    );
    return await crypto.subtle.importKey('raw', bits, { name: 'AES-GCM' }, false, ['wrapKey', 'unwrapKey']);
  } catch { return null; }
}

async function _unlockViaBiometric(mediation: CredentialMediationRequirement): Promise<boolean> {
  const meta = _loadMeta();
  if (!meta?.dekBio) return false;
  const credIdB64 = localStorage.getItem('webauthnCredId');
  const saltB64 = localStorage.getItem('webauthnPrfSalt');
  if (!credIdB64 || !saltB64) return false;

  const kekBio = await _deriveKekFromPrf(_bytes(saltB64), _bytes(credIdB64).buffer, mediation);
  if (!kekBio) return false;

  try {
    appState.vaultKey = await _unwrapDek(kekBio, meta.dekBio);
    appState.vaultMethod = 'master-pw+bio';
    _resetIdleTimer();
    return true;
  } catch { return false; }
}

// Public vault lifecycle

export function vaultExists(): boolean {
  return _loadMeta() !== null;
}

export function vaultHasData(): boolean {
  const raw = localStorage.getItem(VAULT_DATA_KEY);
  if (!raw) return false;
  const vault = JSON.parse(raw) as Record<string, unknown>;
  return Object.keys(vault).length > 0;
}

export function isVaultLocked(): boolean {
  return appState.vaultKey === null && vaultExists();
}

export async function initVault(): Promise<void> {
  const meta = _loadMeta();
  if (!meta) {
    // Check for legacy PasswordCredential vault (migration path)
    if (localStorage.getItem('sshVault') && !localStorage.getItem(VAULT_META_KEY)) {
      appState.vaultMethod = null; // Will need migration
    }
    return;
  }
  appState.vaultMethod = meta.dekBio ? 'master-pw+bio' : 'master-pw';

  // If there's encrypted data, try silent biometric unlock
  if (vaultHasData() && meta.dekBio) {
    await _unlockViaBiometric('silent');
  }
}

/**
 * Create a new vault with a master password.
 * Called from the setup modal on first credential save.
 * Returns true if biometric was also enrolled.
 */
export async function createVault(password: string, enrollBiometric: boolean): Promise<boolean> {
  const salt = crypto.getRandomValues(new Uint8Array(32));
  const dek = await _generateDek();

  // Wrap DEK with password-derived KEK
  const kekPw = await _deriveKekFromPassword(password, salt);
  const dekPw = await _wrapDek(kekPw, dek);

  const meta: VaultMeta = {
    salt: _b64(salt),
    dekPw,
  };
  _saveMeta(meta);

  appState.vaultKey = dek;
  appState.vaultMethod = 'master-pw';
  _resetIdleTimer();

  // Biometric enrollment
  let bioEnrolled = false;
  if (enrollBiometric && prfAvailable()) {
    bioEnrolled = await _webauthnRegisterAndWrapDek(dek);
  }

  return bioEnrolled;
}

/**
 * Unlock the vault with the master password.
 * Returns true on success, false if wrong password or no vault.
 */
export async function unlockWithPassword(password: string): Promise<boolean> {
  const meta = _loadMeta();
  if (!meta) return false;

  try {
    const kekPw = await _deriveKekFromPassword(password, _bytes(meta.salt));
    appState.vaultKey = await _unwrapDek(kekPw, meta.dekPw);
    appState.vaultMethod = meta.dekBio ? 'master-pw+bio' : 'master-pw';
    _resetIdleTimer();
    return true;
  } catch {
    return false; // Wrong password (AES-GCM auth tag mismatch)
  }
}

/**
 * Try to unlock vault, preferring biometric if available.
 * Falls back to returning false (caller should show password prompt).
 */
export async function tryUnlockVault(mediation: CredentialMediationRequirement): Promise<boolean> {
  if (appState.vaultKey) return true;

  const meta = _loadMeta();
  if (!meta) return false;

  // Try biometric first if enrolled
  if (meta.dekBio && mediation !== 'silent') {
    return _unlockViaBiometric(mediation);
  }
  if (meta.dekBio && mediation === 'silent') {
    return _unlockViaBiometric('silent');
  }

  // No biometric — caller must show password prompt
  return false;
}

/**
 * Ensure vault key is available. If vault doesn't exist, returns false
 * (caller must trigger vault creation flow). If vault is locked, attempts
 * biometric unlock; returns false if password entry is needed.
 */
export async function ensureVaultKey(): Promise<boolean> {
  if (appState.vaultKey) {
    _resetIdleTimer();
    return true;
  }
  if (!vaultExists()) return false;
  return tryUnlockVault('required');
}

// Vault CRUD (encrypt/decrypt individual entries)

interface VaultEntry {
  iv: string;
  ct: string;
}

export async function vaultStore(vaultId: string, data: Record<string, unknown>): Promise<void> {
  if (!appState.vaultKey) return;
  _resetIdleTimer();
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv }, appState.vaultKey,
    new TextEncoder().encode(JSON.stringify(data))
  );
  const vault = JSON.parse(localStorage.getItem(VAULT_DATA_KEY) || '{}') as Record<string, VaultEntry>;
  vault[vaultId] = { iv: _b64(iv), ct: _b64(new Uint8Array(ct)) };
  localStorage.setItem(VAULT_DATA_KEY, JSON.stringify(vault));
}

export async function vaultLoad(vaultId: string): Promise<Record<string, unknown> | null> {
  if (!appState.vaultKey) return null;
  _resetIdleTimer();
  const vault = JSON.parse(localStorage.getItem(VAULT_DATA_KEY) || '{}') as Record<string, VaultEntry | undefined>;
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
  const vault = JSON.parse(localStorage.getItem(VAULT_DATA_KEY) || '{}') as Record<string, unknown>;
  const { [vaultId]: _, ...rest } = vault;
  localStorage.setItem(VAULT_DATA_KEY, JSON.stringify(rest));
}

// Vault management (settings)

export async function changePassword(oldPassword: string, newPassword: string): Promise<boolean> {
  const meta = _loadMeta();
  if (!meta) return false;

  // Verify old password by unwrapping DEK
  let dek: CryptoKey;
  try {
    const oldKek = await _deriveKekFromPassword(oldPassword, _bytes(meta.salt));
    dek = await _unwrapDek(oldKek, meta.dekPw);
  } catch {
    return false; // Wrong old password
  }

  // Re-wrap with new password (new salt for forward secrecy)
  const newSalt = crypto.getRandomValues(new Uint8Array(32));
  const newKek = await _deriveKekFromPassword(newPassword, newSalt);
  meta.salt = _b64(newSalt);
  meta.dekPw = await _wrapDek(newKek, dek);
  _saveMeta(meta);

  // DEK stays in memory (already unlocked)
  appState.vaultKey = dek;
  _resetIdleTimer();
  return true;
}

export async function enrollBiometric(): Promise<boolean> {
  if (!appState.vaultKey) return false;
  if (!prfAvailable()) return false;
  // Need extractable DEK for re-wrapping — re-export and re-import
  const dek = appState.vaultKey;
  return _webauthnRegisterAndWrapDek(dek);
}

export function disableBiometric(): void {
  const meta = _loadMeta();
  if (!meta) return;
  delete meta.dekBio;
  _saveMeta(meta);
  localStorage.removeItem('webauthnCredId');
  localStorage.removeItem('webauthnPrfSalt');
  appState.vaultMethod = 'master-pw';
}

export function resetVault(): void {
  lockVault();
  localStorage.removeItem(VAULT_META_KEY);
  localStorage.removeItem(VAULT_DATA_KEY);
  localStorage.removeItem('webauthnCredId');
  localStorage.removeItem('webauthnPrfSalt');
  appState.vaultMethod = null;
}

// Legacy migration (PasswordCredential -> master password)

export function hasLegacyVault(): boolean {
  return !!(localStorage.getItem('sshVault') && !localStorage.getItem(VAULT_META_KEY));
}

/**
 * Migrate legacy vault: caller provides the old vault key (from PasswordCredential)
 * and the new master password. Re-encrypts DEK under the new password KEK.
 */
export async function migrateLegacyVault(oldKey: CryptoKey, newPassword: string): Promise<boolean> {
  const salt = crypto.getRandomValues(new Uint8Array(32));

  // The old key IS the DEK (PasswordCredential stored raw AES key)
  // We need to make it wrappable — export and re-import as extractable
  try {
    const rawBytes = await crypto.subtle.exportKey('raw', oldKey);
    const dek = await crypto.subtle.importKey(
      'raw', rawBytes, { name: 'AES-GCM' }, true, ['encrypt', 'decrypt']
    );

    const kekPw = await _deriveKekFromPassword(newPassword, salt);
    const dekPw = await _wrapDek(kekPw, dek);

    const meta: VaultMeta = { salt: _b64(salt), dekPw };
    _saveMeta(meta);

    // Re-import as non-extractable for runtime use
    appState.vaultKey = await crypto.subtle.importKey(
      'raw', rawBytes, { name: 'AES-GCM' }, false, ['encrypt', 'decrypt']
    );
    appState.vaultMethod = 'master-pw';
    _resetIdleTimer();
    return true;
  } catch { return false; }
}
