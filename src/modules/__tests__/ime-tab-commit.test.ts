import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

/**
 * Tab commit tests (#295, #379).
 *
 * #295: Tab during previewing/editing commits held text + sends \t.
 * #379: Tab should commit ANY text in textarea regardless of IME state,
 *       not just when _isHolding() is true. If the user typed text in
 *       idle or composing state, Tab must commit it before sending \t.
 *
 * Fixed behavior:
 *   1. If _isHolding() && text: recordHistory + sendSSHInput(text) + sendSSHInput(\t) + idle
 *   2. Else if text: recordHistory + sendSSHInput(text) + sendSSHInput(\t) + idle
 *   3. Else (no text): sendSSHInput(\t) + idle
 *   4. Always preventDefault (stop browser focus change)
 */

const imeSrc = readFileSync(resolve(__dirname, '../ime.ts'), 'utf-8');

describe('Tab commits text in all IME states (#379)', () => {
  it('Tab handler commits text even when not holding (idle/composing with text)', () => {
    // The Tab block must have a path that commits text WITHOUT requiring _isHolding()
    // This is the fix for #379: text in textarea during idle/composing gets committed
    const tabBlock = imeSrc.match(
      /if\s*\(e\.key\s*===\s*'Tab'\)\s*\{([\s\S]*?)\n {4}\}/,
    );
    expect(tabBlock, 'Tab handler block should exist').toBeTruthy();

    const block = tabBlock![1]!;
    // Must have a text-only branch (not exclusively behind _isHolding)
    // e.g., "} else if (text) {" or "if (text) {" without _isHolding guard
    const hasNonHoldingTextBranch = /else\s+if\s*\(\s*text\s*\)/.test(block) ||
      // Or: the _isHolding check was removed and only `text` is checked
      (/if\s*\(\s*text\s*\)/.test(block) && !/_isHolding\(\)\s*&&\s*text/.test(
        block.replace(/if\s*\(_isHolding\(\)\s*&&\s*text\)[\s\S]*?}/, ''),
      ));
    expect(
      hasNonHoldingTextBranch,
      'Tab handler must have a branch that commits text when NOT holding',
    ).toBe(true);
  });

  it('Tab always calls preventDefault to stop browser focus change', () => {
    const tabBlock = imeSrc.match(
      /if\s*\(e\.key\s*===\s*'Tab'\)\s*\{([\s\S]*?)\n {4}\}/,
    );
    expect(tabBlock, 'Tab handler block should exist').toBeTruthy();
    const block = tabBlock![1]!;

    // preventDefault must appear in multiple branches (with text, without text)
    const preventDefaultCount = (block.match(/e\.preventDefault\(\)/g) || []).length;
    expect(
      preventDefaultCount,
      'Tab handler should call preventDefault in all branches',
    ).toBeGreaterThanOrEqual(2);
  });

  it('Tab sends \\t even when textarea is empty', () => {
    const tabBlock = imeSrc.match(
      /if\s*\(e\.key\s*===\s*'Tab'\)\s*\{([\s\S]*?)\n {4}\}/,
    );
    expect(tabBlock, 'Tab handler block should exist').toBeTruthy();
    const block = tabBlock![1]!;

    // sendSSHInput('\t') must be reachable in both text and no-text paths
    const sendTabCalls = (block.match(/sendSSHInput\('\\t'\)/g) || []).length;
    expect(
      sendTabCalls,
      "Tab handler should have sendSSHInput('\\t') in both text and no-text paths",
    ).toBeGreaterThanOrEqual(2);
  });
});

describe('Tab in previewing/editing state still works (#295)', () => {
  it('keydown handler has a Tab branch checking _isHolding()', () => {
    const tabHolding = imeSrc.match(
      /e\.key\s*===\s*'Tab'[\s\S]*?_isHolding\(\)/,
    );
    expect(
      tabHolding,
      'Tab handler should check _isHolding() for the held-text path',
    ).toBeTruthy();
  });

  it('sends ime.value via sendSSHInput before sending Tab char', () => {
    const commitThenTab = imeSrc.match(
      /e\.key\s*===\s*'Tab'[\s\S]*?sendSSHInput\(text\)[\s\S]*?sendSSHInput\('\\t'\)/,
    );
    expect(
      commitThenTab,
      "Tab handler should sendSSHInput(text) then sendSSHInput('\\t')",
    ).toBeTruthy();
  });
});

describe('Tab transitions and history (#295, #379)', () => {
  it('calls _recordHistory before committing text on Tab', () => {
    const historyBeforeCommit = imeSrc.match(
      /if\s*\(e\.key\s*===\s*'Tab'\)[\s\S]*?_recordHistory\(text\)[\s\S]*?sendSSHInput\(text\)/,
    );
    expect(
      historyBeforeCommit,
      'Tab handler should call _recordHistory(text) before sendSSHInput(text)',
    ).toBeTruthy();
  });

  it('transitions to idle after committing', () => {
    const tabIdle = imeSrc.match(
      /if\s*\(e\.key\s*===\s*'Tab'\)[\s\S]*?_transition\('idle'\)/,
    );
    expect(
      tabIdle,
      "Tab handler should transition to 'idle' after commit",
    ).toBeTruthy();
  });
});
