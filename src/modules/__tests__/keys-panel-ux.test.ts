/**
 * Tests for keys section UX (#432, updated #441)
 *
 * After #441, key management is an inline <details> section in the Connect
 * panel. The separate #panel-keys no longer exists.
 *
 * Verifies:
 * 1. Inline keysSection exists in Connect panel HTML
 * 2. loadKeys() renders "Edit" button (not "Rename")
 * 3. loadKeys() renders passphrase badge placeholder
 * 4. loadKeys() does NOT render "Use in form" button (#440)
 * 5. editKey() function exists and handles vault passphrase read
 * 6. saveKeyEdit() function exists and writes passphrase to vault
 * 7. cancelKeyEdit() function exists
 * 8. app.ts wires edit/save-edit/cancel-edit actions (no "use" action)
 * 9. #panel-keys is removed from HTML
 * 10. #keys hash redirects to connect in routing
 */
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const profilesSrc = readFileSync(resolve(__dirname, '../profiles.ts'), 'utf-8');
const appSrc = readFileSync(resolve(__dirname, '../../app.ts'), 'utf-8');
const indexHtml = readFileSync(resolve(__dirname, '../../../public/index.html'), 'utf-8');
const uiSrc = readFileSync(resolve(__dirname, '../ui.ts'), 'utf-8');

describe('Keys section UX (#441)', () => {

  describe('Inline keys section in Connect panel', () => {
    it('Connect panel contains a keysSection details element', () => {
      expect(indexHtml).toContain('id="keysSection"');
      expect(indexHtml).toContain('connect-keys-section');
    });

    it('keysSection is inside panel-connect', () => {
      const connectStart = indexHtml.indexOf('id="panel-connect"');
      const connectEnd = indexHtml.indexOf('</div>', indexHtml.indexOf('id="connectNavbar"'));
      const keysPos = indexHtml.indexOf('id="keysSection"');
      expect(keysPos).toBeGreaterThan(connectStart);
      expect(keysPos).toBeLessThan(connectEnd);
    });

    it('separate #panel-keys is removed from HTML', () => {
      expect(indexHtml).not.toContain('id="panel-keys"');
    });

    it('Keys tab is removed from tab bar', () => {
      expect(indexHtml).not.toContain('data-panel="keys"');
    });

    it('keysDoneBtn is removed from HTML', () => {
      expect(indexHtml).not.toContain('id="keysDoneBtn"');
    });
  });

  describe('Edit button replaces Rename', () => {
    it('loadKeys renders Edit button instead of Rename', () => {
      expect(profilesSrc).toContain('data-action="edit"');
      const loadKeysStart = profilesSrc.indexOf('export function loadKeys');
      const loadKeysEnd = profilesSrc.indexOf('\n}', loadKeysStart + 10);
      const loadKeysBody = profilesSrc.slice(loadKeysStart, loadKeysEnd);
      expect(loadKeysBody).not.toContain('data-action="rename"');
      expect(loadKeysBody).toContain('data-action="edit"');
      expect(loadKeysBody).toContain('>Edit<');
    });
  });

  describe('Use in form button removed (#440)', () => {
    it('loadKeys does NOT render Use in form button', () => {
      const loadKeysStart = profilesSrc.indexOf('export function loadKeys');
      const loadKeysEnd = profilesSrc.indexOf('\n}', loadKeysStart + 10);
      const loadKeysBody = profilesSrc.slice(loadKeysStart, loadKeysEnd);
      expect(loadKeysBody).not.toContain('Use in form');
      expect(loadKeysBody).not.toContain('data-action="use"');
    });

    it('useKey is not exported from profiles.ts', () => {
      expect(profilesSrc).not.toContain('export function useKey');
    });

    it('app.ts does not import useKey', () => {
      expect(appSrc).not.toContain('useKey');
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

    it('does NOT handle "use" action in keyList handler', () => {
      // Find the keyList event handler section
      const keyListStart = appSrc.indexOf("getElementById('keyList')");
      const keyListEnd = appSrc.indexOf('});', keyListStart);
      const keyListHandler = appSrc.slice(keyListStart, keyListEnd);
      expect(keyListHandler).not.toContain("'use'");
    });
  });

  describe('Routing', () => {
    it('#keys hash redirects to connect in ui.ts', () => {
      expect(uiSrc).toContain("raw === 'keys'");
      expect(uiSrc).toContain("return 'connect'");
    });

    it('keys is not in VALID_PANELS', () => {
      // The PanelName type should not include 'keys'
      const panelLine = uiSrc.match(/type PanelName = .+/);
      expect(panelLine).toBeTruthy();
      expect(panelLine![0]).not.toContain("'keys'");
    });
  });
});
