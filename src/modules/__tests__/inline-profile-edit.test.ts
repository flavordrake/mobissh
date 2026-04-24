/**
 * Tests for inline per-profile editing (#446)
 *
 * Verifies:
 * 1. editProfile function exists and is exported
 * 2. editProfile creates .profile-edit-form inside profile item
 * 3. autoSaveField persists changes to localStorage
 * 4. Undo reverts the last auto-saved field
 * 5. Only one inline edit open at a time (single-edit constraint)
 * 6. closeProfileEdit removes the form and restores normal display
 * 7. Profile item hides normal content when editing
 */
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const profilesSrc = readFileSync(resolve(__dirname, '../profiles.ts'), 'utf-8');
const appCss = readFileSync(resolve(__dirname, '../../../public/app.css'), 'utf-8');

describe('inline per-profile editing (#446)', () => {

  describe('editProfile function', () => {
    it('is exported from profiles.ts', () => {
      expect(profilesSrc).toContain('export function editProfile(');
    });

    it('creates a .profile-edit-form element', () => {
      const fnStart = profilesSrc.indexOf('export function editProfile(');
      const fnEnd = profilesSrc.indexOf('\n}\n', fnStart + 10);
      const fnBody = profilesSrc.slice(fnStart, fnEnd);
      expect(fnBody).toContain('profile-edit-form');
    });

    it('collapses any existing inline edit first', () => {
      const fnStart = profilesSrc.indexOf('export function editProfile(');
      const fnEnd = profilesSrc.indexOf('\n}\n', fnStart + 10);
      const fnBody = profilesSrc.slice(fnStart, fnEnd);
      expect(fnBody).toContain('closeProfileEdit');
    });

    it('hides normal profile content while editing', () => {
      const fnStart = profilesSrc.indexOf('export function editProfile(');
      const fnEnd = profilesSrc.indexOf('\n}\n', fnStart + 10);
      const fnBody = profilesSrc.slice(fnStart, fnEnd);
      expect(fnBody).toContain('profile-editing');
    });

    it('calls scrollIntoView after expanding', () => {
      const fnStart = profilesSrc.indexOf('export function editProfile(');
      const fnEnd = profilesSrc.indexOf('\n}\n', fnStart + 10);
      const fnBody = profilesSrc.slice(fnStart, fnEnd);
      expect(fnBody).toContain('scrollIntoView');
    });
  });

  describe('autoSaveField function', () => {
    it('is exported from profiles.ts', () => {
      expect(profilesSrc).toContain('export function autoSaveField(');
    });

    it('persists to localStorage via saveProfiles pattern', () => {
      const fnStart = profilesSrc.indexOf('export function autoSaveField(');
      const fnEnd = profilesSrc.indexOf('\n}\n', fnStart + 10);
      const fnBody = profilesSrc.slice(fnStart, fnEnd);
      expect(fnBody).toContain('localStorage.setItem');
    });

    it('shows undo toast after saving', () => {
      const fnStart = profilesSrc.indexOf('export function autoSaveField(');
      const fnEnd = profilesSrc.indexOf('\n}\n', fnStart + 10);
      const fnBody = profilesSrc.slice(fnStart, fnEnd);
      expect(fnBody).toContain('Undo');
    });
  });

  describe('closeProfileEdit function', () => {
    it('is exported from profiles.ts', () => {
      expect(profilesSrc).toContain('export function closeProfileEdit(');
    });

    it('removes the profile-edit-form', () => {
      const fnStart = profilesSrc.indexOf('export function closeProfileEdit(');
      const fnEnd = profilesSrc.indexOf('\n}\n', fnStart + 10);
      const fnBody = profilesSrc.slice(fnStart, fnEnd);
      expect(fnBody).toContain('.remove()');
    });

    it('restores normal profile display', () => {
      const fnStart = profilesSrc.indexOf('export function closeProfileEdit(');
      const fnEnd = profilesSrc.indexOf('\n}\n', fnStart + 10);
      const fnBody = profilesSrc.slice(fnStart, fnEnd);
      expect(fnBody).toContain('profile-editing');
    });
  });

  describe('CSS styles', () => {
    it('has .profile-edit-form styles', () => {
      expect(appCss).toContain('.profile-edit-form');
    });

    it('has .profile-editing class to hide normal content', () => {
      expect(appCss).toContain('.profile-editing');
    });

    it('has .undo-toast styles', () => {
      expect(appCss).toContain('.undo-toast');
    });

    it('gives the color input a visible size (not 0×0 in the grid cell)', () => {
      expect(appCss).toMatch(/\.profile-color-input[\s\S]*?width:\s*\d+px/);
      expect(appCss).toMatch(/\.profile-color-input[\s\S]*?height:\s*\d+px/);
    });

    it('preserves the native color swatch (does not force transparent background)', () => {
      // Regression: an earlier iteration set background:transparent which
      // blanked the picker on Android Chromium.
      const ruleStart = appCss.indexOf('.profile-color-input');
      const ruleEnd = appCss.indexOf('}', ruleStart);
      const rule = appCss.slice(ruleStart, ruleEnd);
      expect(rule).not.toMatch(/background\s*:\s*transparent/);
      expect(rule).toMatch(/appearance\s*:\s*auto/);
    });
  });

  describe('profile color field (#per-profile accent)', () => {
    it('inline edit form renders a color input with data-field="color"', () => {
      const fnStart = profilesSrc.indexOf('export function editProfile(');
      const fnEnd = profilesSrc.indexOf('\n}\n', fnStart + 10);
      const fnBody = profilesSrc.slice(fnStart, fnEnd);
      expect(fnBody).toMatch(/type="color"[^>]*data-field="color"/);
    });

    it('inline edit form renders a Reset button', () => {
      const fnStart = profilesSrc.indexOf('export function editProfile(');
      const fnEnd = profilesSrc.indexOf('\n}\n', fnStart + 10);
      const fnBody = profilesSrc.slice(fnStart, fnEnd);
      expect(fnBody).toContain('data-action="reset-color"');
    });

    it('Reset handler clears the explicit color via autoSaveField', () => {
      const fnStart = profilesSrc.indexOf('export function editProfile(');
      const fnEnd = profilesSrc.indexOf('\n}\n', fnStart + 10);
      const fnBody = profilesSrc.slice(fnStart, fnEnd);
      expect(fnBody).toMatch(/reset-color[\s\S]*?autoSaveField\(idx, 'color', ''\)/);
    });

    it('profileColor helper falls back to theme accent when color is unset', () => {
      expect(profilesSrc).toMatch(/export function profileColor/);
      expect(profilesSrc).toMatch(/THEMES\[theme\]\.app\.accent/);
    });
  });

  describe('app.ts wiring', () => {
    const appSrc = readFileSync(resolve(__dirname, '../../app.ts'), 'utf-8');

    it('imports editProfile from profiles', () => {
      expect(appSrc).toContain('editProfile');
    });

    it('calls editProfile on edit action instead of loadProfileIntoForm', () => {
      // The profileList click handler should call editProfile, not loadProfileIntoForm
      const handlerStart = appSrc.indexOf("profileList.addEventListener('click'");
      const handlerEnd = appSrc.indexOf('});', handlerStart + 10);
      const handler = appSrc.slice(handlerStart, handlerEnd);
      expect(handler).toContain('editProfile(idx)');
      expect(handler).not.toContain('loadProfileIntoForm(idx)');
    });
  });
});
