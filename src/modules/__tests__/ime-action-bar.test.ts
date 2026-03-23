import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

/**
 * IME action bar positioning and button state tests (#265).
 *
 * The action bar (#imeActions) contains 5 buttons: imeHistoryUp (▲),
 * imeHistoryDown (▼), imeClearBtn (✕), imeCommitBtn (✓), imeDockToggle (↕).
 * It must reposition correctly when dock position or viewport changes.
 *
 * These tests verify the structural contracts in ime.ts source — button wiring,
 * positioning formulas, disabled-state logic, and viewport event handlers.
 */

const imeSrc = readFileSync(resolve(__dirname, '../ime.ts'), 'utf-8');

describe('action bar button wiring (#265)', () => {
  const BUTTON_IDS = [
    'imeHistoryUp',
    'imeHistoryDown',
    'imeClearBtn',
    'imeCommitBtn',
    'imeDockToggle',
  ];

  for (const id of BUTTON_IDS) {
    it(`getElementById references "${id}"`, () => {
      expect(imeSrc).toContain(`getElementById('${id}')`);
    });
  }

  it('references all 5 action buttons', () => {
    for (const id of BUTTON_IDS) {
      expect(imeSrc).toContain(id);
    }
  });

  it('all 5 buttons are wired via _onAction helper', () => {
    expect(imeSrc).toContain('_onAction(clearBtn,');
    expect(imeSrc).toContain('_onAction(commitBtn,');
    expect(imeSrc).toContain('_onAction(dockToggle,');
    expect(imeSrc).toContain('_onAction(historyUp,');
    expect(imeSrc).toContain('_onAction(historyDown,');
  });

  it('action bar gets mousedown preventDefault to prevent focus stealing', () => {
    const match = imeSrc.match(
      /imeActions\.addEventListener\('mousedown'[^}]*preventDefault/s,
    );
    expect(match, 'imeActions should have mousedown preventDefault').toBeTruthy();
  });
});

describe('_positionIME dock top (#265)', () => {
  it('action bar top = textarea top + offsetHeight', () => {
    expect(imeSrc).toContain('imeActions.style.top = `${String(top + ime.offsetHeight)}px`');
  });

  it('action bar bottom = auto when docked top', () => {
    expect(imeSrc).toContain("imeActions.style.bottom = 'auto'");
  });
});

describe('_positionIME dock bottom (#265)', () => {
  it('action bar bottom is set from viewport calculation', () => {
    expect(imeSrc).toContain('imeActions.style.bottom = `${String(bottom)}px`');
  });

  it('action bar top = auto when docked bottom', () => {
    expect(imeSrc).toContain("imeActions.style.top = 'auto'");
  });
});

describe('history button disabled state (#265)', () => {
  it('toggles disabled class on historyUp based on history length', () => {
    expect(imeSrc).toContain("historyUp.classList.toggle('disabled', !hasHistory)");
  });

  it('toggles disabled class on historyDown based on history length', () => {
    expect(imeSrc).toContain("historyDown.classList.toggle('disabled', !hasHistory)");
  });

  it('hasHistory is derived from _commitHistory.length > 0', () => {
    expect(imeSrc).toContain('const hasHistory = _commitHistory.length > 0');
  });

  it('_showActions calls _positionIME after updating button state', () => {
    const showActionsMatch = imeSrc.match(
      /function _showActions\(\)[^}]*classList\.toggle\('disabled'[^}]*_positionIME\(\)/s,
    );
    expect(showActionsMatch, '_showActions should toggle disabled then call _positionIME').toBeTruthy();
  });

  it('_showActions removes hidden class from imeActions', () => {
    expect(imeSrc).toContain("imeActions.classList.remove('hidden')");
  });
});

describe('dock toggle persists and repositions (#265)', () => {
  it('persists dock position to localStorage on toggle', () => {
    expect(imeSrc).toContain("localStorage.setItem('imeDockPosition', _dockPosition)");
  });

  it('calls _positionIME after dock toggle', () => {
    const toggleBlock = imeSrc.match(
      /dockToggle,\s*\(\)\s*=>\s*\{[^}]*_positionIME\(\)/s,
    );
    expect(toggleBlock, 'dock toggle handler should call _positionIME').toBeTruthy();
  });
});

describe('viewport events trigger repositioning (#265)', () => {
  it('registers resize listener on visualViewport', () => {
    expect(imeSrc).toContain("visualViewport.addEventListener('resize'");
  });

  it('registers scroll listener on visualViewport', () => {
    expect(imeSrc).toContain("visualViewport.addEventListener('scroll'");
  });

  it('resize handler calls _positionIME when ime-visible', () => {
    const resizeMatch = imeSrc.match(
      /visualViewport\.addEventListener\('resize'[^}]*ime-visible[^}]*_positionIME/s,
    );
    expect(resizeMatch, 'resize handler should call _positionIME when visible').toBeTruthy();
  });

  it('scroll handler calls _positionIME when ime-visible', () => {
    const scrollMatch = imeSrc.match(
      /visualViewport\.addEventListener\('scroll'[^}]*ime-visible[^}]*_positionIME/s,
    );
    expect(scrollMatch, 'scroll handler should call _positionIME when visible').toBeTruthy();
  });
});
