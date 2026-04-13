/**
 * Tests for scrollIntoView on inline edit forms (#434)
 * Updated for details-based form toggle
 *
 * Verifies:
 * 1. editKey() calls scrollIntoView after appending the form
 * 2. revealConnectForm() uses details.open and calls scrollIntoView
 */
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const profilesSrc = readFileSync(resolve(__dirname, '../profiles.ts'), 'utf-8');

describe('scrollIntoView on form expand (#434)', () => {

  describe('editKey inline form', () => {
    it('calls scrollIntoView after appendChild(form)', () => {
      const fnStart = profilesSrc.indexOf('export async function editKey');
      const fnEnd = profilesSrc.indexOf('\n}', fnStart + 10);
      const fnBody = profilesSrc.slice(fnStart, fnEnd);

      const appendIdx = fnBody.indexOf('item.appendChild(form)');
      const scrollIdx = fnBody.indexOf('form.scrollIntoView(');
      expect(appendIdx).toBeGreaterThan(-1);
      expect(scrollIdx).toBeGreaterThan(-1);
      expect(scrollIdx).toBeGreaterThan(appendIdx);
    });

    it('uses smooth behavior and nearest block', () => {
      const fnStart = profilesSrc.indexOf('export async function editKey');
      const fnEnd = profilesSrc.indexOf('\n}', fnStart + 10);
      const fnBody = profilesSrc.slice(fnStart, fnEnd);
      expect(fnBody).toContain("behavior: 'smooth'");
      expect(fnBody).toContain("block: 'nearest'");
    });
  });

  describe('revealConnectForm', () => {
    it('sets details.open = true on the form section', () => {
      const fnStart = profilesSrc.indexOf('export function revealConnectForm');
      const fnEnd = profilesSrc.indexOf('\n}', fnStart + 10);
      const fnBody = profilesSrc.slice(fnStart, fnEnd);

      expect(fnBody).toContain('section.open = true');
    });

    it('calls scrollIntoView on the form section', () => {
      const fnStart = profilesSrc.indexOf('export function revealConnectForm');
      const fnEnd = profilesSrc.indexOf('\n}', fnStart + 10);
      const fnBody = profilesSrc.slice(fnStart, fnEnd);

      expect(fnBody).toContain('scrollIntoView(');
      expect(fnBody).toContain("behavior: 'smooth'");
      expect(fnBody).toContain("block: 'nearest'");
    });
  });
});
