/**
 * Tests for keys panel UX improvements (#432)
 *
 * Verifies:
 * 1. Done/back button exists in keys panel HTML
 * 2. loadKeys() renders "Edit" button (not "Rename")
 * 3. loadKeys() renders passphrase badge placeholder
 * 4. editKey() function exists and handles vault passphrase read
 * 5. saveKeyEdit() function exists and writes passphrase to vault
 * 6. cancelKeyEdit() function exists
 * 7. app.ts wires edit/save-edit/cancel-edit actions
 */
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const profilesSrc = readFileSync(resolve(__dirname, '../profiles.ts'), 'utf-8');
const appSrc = readFileSync(resolve(__dirname, '../../app.ts'), 'utf-8');
const indexHtml = readFileSync(resolve(__dirname, '../../../public/index.html'), 'utf-8');

describe('Keys panel UX (#432)', () => {

  describe('Done/back button', () => {
    it('keys panel contains a Done button in HTML', () => {
      expect(indexHtml).toContain('id="keysDoneBtn"');
      expect(indexHtml).toContain('panel-done-btn');
    });

    it('app.ts wires keysDoneBtn to navigateToPanel connect', () => {
      expect(appSrc).toContain('keysDoneBtn');
      expect(appSrc).toContain("navigateToPanel('connect'");
    });
  });

  describe('Edit button replaces Rename', () => {
    it('loadKeys renders Edit button instead of Rename', () => {
      // The loadKeys function should produce buttons with data-action="edit"
      expect(profilesSrc).toContain('data-action="edit"');
      // Should NOT contain data-action="rename" in the loadKeys HTML template
      const loadKeysStart = profilesSrc.indexOf('export function loadKeys');
      const loadKeysEnd = profilesSrc.indexOf('\n}', loadKeysStart + 10);
      const loadKeysBody = profilesSrc.slice(loadKeysStart, loadKeysEnd);
      expect(loadKeysBody).not.toContain('data-action="rename"');
      expect(loadKeysBody).toContain('data-action="edit"');
      expect(loadKeysBody).toContain('>Edit<');
    });
  });

  describe('Passphrase indicator', () => {
    it('loadKeys renders passphrase badge placeholder', () => {
      expect(profilesSrc).toContain('key-passphrase-badge');
    });

    it('_updatePassphraseBadges checks vault for passphrase', () => {
      expect(profilesSrc).toContain('_updatePassphraseBadges');
      expect(profilesSrc).toContain('vaultLoad');
      expect(profilesSrc).toContain('Passphrase set');
    });
  });

  describe('editKey function', () => {
    it('editKey is exported and async', () => {
      expect(profilesSrc).toContain('export async function editKey');
    });

    it('editKey loads passphrase from vault', () => {
      const fnStart = profilesSrc.indexOf('export async function editKey');
      const fnSlice = profilesSrc.slice(fnStart, fnStart + 800);
      expect(fnSlice).toContain('vaultLoad');
      expect(fnSlice).toContain('passphrase');
    });

    it('editKey creates an inline edit form', () => {
      const fnStart = profilesSrc.indexOf('export async function editKey');
      const fnSlice = profilesSrc.slice(fnStart, fnStart + 1500);
      expect(fnSlice).toContain('key-edit-form');
      expect(fnSlice).toContain('editKeyName');
      expect(fnSlice).toContain('editKeyPass');
    });
  });

  describe('saveKeyEdit function', () => {
    it('saveKeyEdit is exported and async', () => {
      expect(profilesSrc).toContain('export async function saveKeyEdit');
    });

    it('saveKeyEdit writes passphrase to vault', () => {
      const fnStart = profilesSrc.indexOf('export async function saveKeyEdit');
      const fnSlice = profilesSrc.slice(fnStart, fnStart + 1000);
      expect(fnSlice).toContain('vaultLoad');
      expect(fnSlice).toContain('vaultStore');
      expect(fnSlice).toContain('passphrase');
    });
  });

  describe('cancelKeyEdit function', () => {
    it('cancelKeyEdit is exported', () => {
      expect(profilesSrc).toContain('export function cancelKeyEdit');
    });
  });

  describe('app.ts wiring', () => {
    it('imports editKey, saveKeyEdit, cancelKeyEdit', () => {
      expect(appSrc).toContain('editKey');
      expect(appSrc).toContain('saveKeyEdit');
      expect(appSrc).toContain('cancelKeyEdit');
    });

    it('handles edit, save-edit, cancel-edit actions in keyList handler', () => {
      expect(appSrc).toContain("'edit'");
      expect(appSrc).toContain("'save-edit'");
      expect(appSrc).toContain("'cancel-edit'");
    });
  });
});
