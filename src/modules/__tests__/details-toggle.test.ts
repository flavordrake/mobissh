/**
 * Tests for details-based connect form toggle
 *
 * Verifies:
 * 1. loadProfiles collapses form (details.open = false) when profiles exist
 * 2. loadProfiles expands form (details.open = true) when no profiles
 * 3. newConnection resets summary to "New Connection"
 * 4. loadProfileIntoForm sets summary to "Edit Profile"
 * 5. No references to newConnBtn or connect-form-hidden class
 */
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const profilesSrc = readFileSync(resolve(__dirname, '../profiles.ts'), 'utf-8');
const uiSrc = readFileSync(resolve(__dirname, '../ui.ts'), 'utf-8');
const indexHtml = readFileSync(resolve(__dirname, '../../../public/index.html'), 'utf-8');

describe('details-based connect form toggle', () => {

  it('index.html uses <details> element for connect-form-section', () => {
    expect(indexHtml).toContain('<details id="connect-form-section">');
    expect(indexHtml).toContain('<summary>New Connection</summary>');
  });

  it('index.html does not contain newConnBtn', () => {
    expect(indexHtml).not.toContain('id="newConnBtn"');
  });

  it('profiles.ts does not reference connect-form-hidden class', () => {
    expect(profilesSrc).not.toContain('connect-form-hidden');
  });

  it('profiles.ts does not reference newConnBtn', () => {
    expect(profilesSrc).not.toContain('newConnBtn');
  });

  it('ui.ts does not reference newConnBtn', () => {
    expect(uiSrc).not.toContain('newConnBtn');
  });

  it('ui.ts does not reference connect-form-hidden', () => {
    expect(uiSrc).not.toContain('connect-form-hidden');
  });

  describe('loadProfiles', () => {
    it('sets details.open = false when profiles exist', () => {
      const fnStart = profilesSrc.indexOf('export function loadProfiles');
      const fnEnd = profilesSrc.indexOf('\n}\n', fnStart + 10);
      const fnBody = profilesSrc.slice(fnStart, fnEnd);

      expect(fnBody).toContain('formSection.open = false');
    });

    it('sets details.open = true when no profiles', () => {
      const fnStart = profilesSrc.indexOf('export function loadProfiles');
      const fnEnd = profilesSrc.indexOf('\n}\n', fnStart + 10);
      const fnBody = profilesSrc.slice(fnStart, fnEnd);

      expect(fnBody).toContain('formSection.open = true');
    });
  });

  describe('newConnection', () => {
    it('updates summary to New Connection', () => {
      const fnStart = profilesSrc.indexOf('export function newConnection');
      const fnEnd = profilesSrc.indexOf('\n}', fnStart + 10);
      const fnBody = profilesSrc.slice(fnStart, fnEnd);

      expect(fnBody).toContain("_updateFormSummary('New Connection')");
    });
  });

  describe('loadProfileIntoForm', () => {
    it('updates summary to Edit Profile', () => {
      const fnStart = profilesSrc.indexOf('export async function loadProfileIntoForm');
      const fnEnd = profilesSrc.indexOf('\n}\n', fnStart + 10);
      const fnBody = profilesSrc.slice(fnStart, fnEnd);

      expect(fnBody).toContain("_updateFormSummary('Edit Profile')");
    });
  });

  describe('ui.ts save handler', () => {
    it('collapses form after save by setting details.open = false', () => {
      const saveIdx = uiSrc.indexOf('void saveProfile(profile)');
      const nextHandler = uiSrc.indexOf('addEventListener', saveIdx + 10);
      const saveBlock = uiSrc.slice(saveIdx, nextHandler);

      expect(saveBlock).toContain('formSection.open = false');
    });
  });
});
