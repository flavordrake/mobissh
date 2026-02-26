/**
 * modules/vault-ui.ts — Vault UI controller
 *
 * Manages the master password setup modal, inline unlock bar,
 * change-password modal, and vault settings section.
 * Bridges the vault.ts crypto core with the DOM.
 */

import { appState } from './state.js';
import {
  vaultExists, isVaultLocked, lockVault, createVault,
  unlockWithPassword, changePassword, prfAvailable,
  enrollBiometric, disableBiometric, resetVault,
  tryUnlockVault, hasLegacyVault,
} from './vault.js';

let _toast = (_msg: string): void => {};

export interface VaultUIDeps {
  toast: (msg: string) => void;
}

export function initVaultUI({ toast }: VaultUIDeps): void {
  _toast = toast;
  _initSetupModal();
  _initUnlockBar();
  _initChangePwModal();
  _initVaultSettings();
}

// Password strength estimation (simple, no library)
function _estimateStrength(pw: string): number {
  if (!pw) return 0;
  let score = 0;
  if (pw.length >= 4) score += 20;
  if (pw.length >= 8) score += 20;
  if (pw.length >= 12) score += 10;
  if (/[a-z]/.test(pw) && /[A-Z]/.test(pw)) score += 15;
  if (/\d/.test(pw)) score += 15;
  if (/[^a-zA-Z0-9]/.test(pw)) score += 20;
  return Math.min(score, 100);
}

function _strengthColor(pct: number): string {
  if (pct < 30) return 'var(--danger)';
  if (pct < 60) return '#ffaa00';
  return 'var(--accent)';
}

// Pending vault creation callback — set when ensureVaultKey triggers the modal
let _pendingCreateResolve: ((created: boolean) => void) | null = null;

/**
 * Show the vault setup modal and return a Promise that resolves when
 * the user creates the vault (true) or cancels (false).
 */
export function showVaultSetup(): Promise<boolean> {
  const overlay = document.getElementById('vaultSetupOverlay')!;
  const pwInput = document.getElementById('vaultNewPw') as HTMLInputElement;
  const confirmInput = document.getElementById('vaultConfirmPw') as HTMLInputElement;
  const errorEl = document.getElementById('vaultPwError')!;
  const bioOption = document.getElementById('vaultBioOption')!;

  // Reset fields
  pwInput.value = '';
  confirmInput.value = '';
  errorEl.classList.add('hidden');
  errorEl.textContent = '';
  _updateStrength('');

  // Show biometric toggle if PRF is available
  if (prfAvailable()) {
    bioOption.classList.remove('hidden');
    (document.getElementById('vaultEnableBio') as HTMLInputElement).checked = true;
  } else {
    bioOption.classList.add('hidden');
  }

  overlay.classList.remove('hidden');
  pwInput.focus();

  return new Promise<boolean>((resolve) => {
    _pendingCreateResolve = resolve;
  });
}

function _updateStrength(pw: string): void {
  const meter = document.getElementById('vaultStrength');
  if (!meter) return;
  const pct = _estimateStrength(pw);
  meter.style.setProperty('--strength', `${String(pct)}%`);
  meter.style.setProperty('--strength-color', _strengthColor(pct));
}

function _initSetupModal(): void {
  const overlay = document.getElementById('vaultSetupOverlay')!;
  const pwInput = document.getElementById('vaultNewPw') as HTMLInputElement;
  const confirmInput = document.getElementById('vaultConfirmPw') as HTMLInputElement;
  const errorEl = document.getElementById('vaultPwError')!;
  const createBtn = document.getElementById('vaultSetupCreate')!;
  const cancelBtn = document.getElementById('vaultSetupCancel')!;

  pwInput.addEventListener('input', () => {
    _updateStrength(pwInput.value);
  });

  createBtn.addEventListener('click', () => {
    const pw = pwInput.value;
    const confirm = confirmInput.value;

    if (!pw) {
      errorEl.textContent = 'Password is required';
      errorEl.classList.remove('hidden');
      return;
    }
    if (pw !== confirm) {
      errorEl.textContent = 'Passwords do not match';
      errorEl.classList.remove('hidden');
      return;
    }

    errorEl.classList.add('hidden');
    const enrollBio = prfAvailable() && (document.getElementById('vaultEnableBio') as HTMLInputElement).checked;

    void createVault(pw, enrollBio).then((bioEnrolled) => {
      overlay.classList.add('hidden');
      if (bioEnrolled) {
        _toast('Vault created with fingerprint unlock');
      } else {
        _toast('Vault created');
      }
      updateVaultSettingsUI();
      _pendingCreateResolve?.(true);
      _pendingCreateResolve = null;
    }).catch(() => {
      overlay.classList.add('hidden');
      _toast('Vault creation failed');
      _pendingCreateResolve?.(false);
      _pendingCreateResolve = null;
    });
  });

  cancelBtn.addEventListener('click', () => {
    overlay.classList.add('hidden');
    _pendingCreateResolve?.(false);
    _pendingCreateResolve = null;
  });
}

// Inline unlock bar

let _pendingUnlockResolve: ((unlocked: boolean) => void) | null = null;

/**
 * Show the inline unlock bar and return a Promise that resolves
 * when the user unlocks (true) or the attempt is abandoned (false).
 */
export function showUnlockBar(): Promise<boolean> {
  const bar = document.getElementById('vaultUnlockBar')!;
  const pwInput = document.getElementById('vaultUnlockPw') as HTMLInputElement;
  const errorEl = document.getElementById('vaultUnlockError')!;

  pwInput.value = '';
  errorEl.classList.add('hidden');
  bar.classList.remove('hidden');
  pwInput.focus();

  return new Promise<boolean>((resolve) => {
    _pendingUnlockResolve = resolve;
  });
}

export function hideUnlockBar(): void {
  document.getElementById('vaultUnlockBar')?.classList.add('hidden');
  _pendingUnlockResolve?.(false);
  _pendingUnlockResolve = null;
}

function _initUnlockBar(): void {
  const pwInput = document.getElementById('vaultUnlockPw') as HTMLInputElement;
  const unlockBtn = document.getElementById('vaultUnlockBtn')!;
  const errorEl = document.getElementById('vaultUnlockError')!;

  const doUnlock = (): void => {
    const pw = pwInput.value;
    if (!pw) return;

    void unlockWithPassword(pw).then((ok) => {
      if (ok) {
        document.getElementById('vaultUnlockBar')!.classList.add('hidden');
        errorEl.classList.add('hidden');
        _toast('Credentials unlocked');
        updateVaultSettingsUI();
        _pendingUnlockResolve?.(true);
        _pendingUnlockResolve = null;
      } else {
        errorEl.classList.remove('hidden');
        pwInput.value = '';
        pwInput.focus();
      }
    });
  };

  unlockBtn.addEventListener('click', doUnlock);
  pwInput.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') doUnlock();
  });
}

// Change password modal

function _initChangePwModal(): void {
  const overlay = document.getElementById('vaultChangePwOverlay')!;
  const oldPwInput = document.getElementById('vaultOldPw') as HTMLInputElement;
  const newPwInput = document.getElementById('vaultChangePwNew') as HTMLInputElement;
  const confirmInput = document.getElementById('vaultChangePwConfirm') as HTMLInputElement;
  const errorEl = document.getElementById('vaultChangePwError')!;
  const saveBtn = document.getElementById('vaultChangePwSave')!;
  const cancelBtn = document.getElementById('vaultChangePwCancel')!;

  saveBtn.addEventListener('click', () => {
    const oldPw = oldPwInput.value;
    const newPw = newPwInput.value;
    const confirm = confirmInput.value;

    if (!oldPw || !newPw) {
      errorEl.textContent = 'All fields are required';
      errorEl.classList.remove('hidden');
      return;
    }
    if (newPw !== confirm) {
      errorEl.textContent = 'New passwords do not match';
      errorEl.classList.remove('hidden');
      return;
    }

    void changePassword(oldPw, newPw).then((ok) => {
      if (ok) {
        overlay.classList.add('hidden');
        _toast('Master password changed');
      } else {
        errorEl.textContent = 'Current password is incorrect';
        errorEl.classList.remove('hidden');
      }
    });
  });

  cancelBtn.addEventListener('click', () => {
    overlay.classList.add('hidden');
  });
}

function _showChangePwModal(): void {
  const overlay = document.getElementById('vaultChangePwOverlay')!;
  const oldPwInput = document.getElementById('vaultOldPw') as HTMLInputElement;
  const newPwInput = document.getElementById('vaultChangePwNew') as HTMLInputElement;
  const confirmInput = document.getElementById('vaultChangePwConfirm') as HTMLInputElement;
  const errorEl = document.getElementById('vaultChangePwError')!;

  oldPwInput.value = '';
  newPwInput.value = '';
  confirmInput.value = '';
  errorEl.classList.add('hidden');
  overlay.classList.remove('hidden');
  oldPwInput.focus();
}

// Vault settings section

function _initVaultSettings(): void {
  document.getElementById('vaultLockBtn')!.addEventListener('click', () => {
    lockVault();
    _toast('Vault locked');
    updateVaultSettingsUI();
  });

  document.getElementById('vaultChangePwBtn')!.addEventListener('click', () => {
    _showChangePwModal();
  });

  document.getElementById('vaultEnableBioBtn')!.addEventListener('click', () => {
    void enrollBiometric().then((ok) => {
      if (ok) {
        _toast('Fingerprint unlock enabled');
      } else {
        _toast('Could not enable fingerprint unlock');
      }
      updateVaultSettingsUI();
    });
  });

  document.getElementById('vaultDisableBioBtn')!.addEventListener('click', () => {
    disableBiometric();
    _toast('Fingerprint unlock disabled');
    updateVaultSettingsUI();
  });

  document.getElementById('vaultResetBtn')!.addEventListener('click', () => {
    if (!confirm('This will delete all saved credentials. You will need to re-enter them.')) return;
    resetVault();
    _toast('Vault reset');
    updateVaultSettingsUI();
  });

  updateVaultSettingsUI();
}

export function updateVaultSettingsUI(): void {
  const statusEl = document.getElementById('vaultStatus');
  const lockBtn = document.getElementById('vaultLockBtn')!;
  const changePwBtn = document.getElementById('vaultChangePwBtn')!;
  const enableBioBtn = document.getElementById('vaultEnableBioBtn')!;
  const disableBioBtn = document.getElementById('vaultDisableBioBtn')!;
  const resetBtn = document.getElementById('vaultResetBtn')!;

  // Hide all by default
  lockBtn.classList.add('hidden');
  changePwBtn.classList.add('hidden');
  enableBioBtn.classList.add('hidden');
  disableBioBtn.classList.add('hidden');
  resetBtn.classList.add('hidden');

  if (!vaultExists() && !hasLegacyVault()) {
    if (statusEl) statusEl.textContent = 'Not set up';
    return;
  }

  if (hasLegacyVault() && !vaultExists()) {
    if (statusEl) statusEl.textContent = 'Legacy vault (needs migration)';
    resetBtn.classList.remove('hidden');
    return;
  }

  const locked = isVaultLocked();
  const hasBio = appState.vaultMethod === 'master-pw+bio';

  if (locked) {
    if (statusEl) statusEl.textContent = 'Locked';
  } else {
    if (statusEl) statusEl.textContent = hasBio ? 'Unlocked (password + fingerprint)' : 'Unlocked (password only)';
    lockBtn.classList.remove('hidden');
    changePwBtn.classList.remove('hidden');

    if (hasBio) {
      disableBioBtn.classList.remove('hidden');
    } else if (prfAvailable()) {
      enableBioBtn.classList.remove('hidden');
    }
  }

  resetBtn.classList.remove('hidden');
}

/**
 * On first launch (no vault in localStorage), show the vault setup modal
 * immediately so the user creates their master password before interacting
 * with the app. This decouples vault creation from the SSH connect flow.
 *
 * No-op if a vault already exists or is unlocked.
 */
export async function promptVaultSetupOnStartup(): Promise<void> {
  if (vaultExists()) return;
  if (hasLegacyVault()) return;
  if (appState.vaultKey) return;
  await showVaultSetup();
}

/**
 * Ensure vault key is available, with UI flows for creation and unlock.
 * This replaces direct calls to vault.ensureVaultKey() from profiles.ts.
 *
 * Returns true if vault key is now available, false if user cancelled.
 */
export async function ensureVaultKeyWithUI(): Promise<boolean> {
  // Already unlocked
  if (appState.vaultKey) return true;

  // No vault exists — show setup modal
  if (!vaultExists()) {
    return showVaultSetup();
  }

  // Vault exists but is locked — try biometric first
  const bioUnlocked = await tryUnlockVault('required');
  if (bioUnlocked) {
    updateVaultSettingsUI();
    return true;
  }

  // Biometric failed or not enrolled — show password prompt
  return showUnlockBar();
}
