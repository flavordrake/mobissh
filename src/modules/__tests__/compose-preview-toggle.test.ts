import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

/**
 * Compose/preview button ordering and toggle styling (#407).
 *
 * 1. Preview button (eye) should appear BEFORE compose button (pencil) in DOM
 *    so preview is on the left, compose on the right (closer to text area).
 * 2. Both buttons should have accent background when active — compose button
 *    must match the preview button's active pattern (accent color + bg).
 */

const htmlSrc = readFileSync(resolve(__dirname, '../../../public/index.html'), 'utf-8');
const cssSrc = readFileSync(resolve(__dirname, '../../../public/app.css'), 'utf-8');

describe('#407: compose/preview icon positions', () => {
  it('previewModeBtn appears before composeModeBtn in DOM order', () => {
    const previewIdx = htmlSrc.indexOf('id="previewModeBtn"');
    const composeIdx = htmlSrc.indexOf('id="composeModeBtn"');
    expect(previewIdx).toBeGreaterThan(-1);
    expect(composeIdx).toBeGreaterThan(-1);
    expect(previewIdx).toBeLessThan(composeIdx);
  });
});

describe('#407: compose button active styling', () => {
  it('compose-active has accent background (matching preview-active)', () => {
    // Extract the compose-active rule
    const composeRule = cssSrc.match(
      /\.handle-compose-btn\.compose-active\s*\{[^}]*\}/,
    );
    expect(composeRule, 'compose-active CSS rule should exist').toBeTruthy();
    expect(composeRule![0]).toContain('background');
    expect(composeRule![0]).toContain('color: var(--accent)');
  });

  it('preview-active has accent background', () => {
    const previewRule = cssSrc.match(
      /\.handle-preview-btn\.preview-active\s*\{[^}]*\}/,
    );
    expect(previewRule, 'preview-active CSS rule should exist').toBeTruthy();
    expect(previewRule![0]).toContain('background');
    expect(previewRule![0]).toContain('color: var(--accent)');
  });
});
