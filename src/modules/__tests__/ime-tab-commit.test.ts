import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

/**
 * Tab-during-preview commit tests (#295).
 *
 * When Tab is pressed during previewing or editing state, the IME should:
 *   1. Commit the held text (sendSSHInput with ime.value)
 *   2. Send a Tab character (sendSSHInput with '\t') for autocomplete
 *   3. Transition to idle state
 *   4. Record history before committing
 *
 * These are TDD red-baseline tests — they describe the DESIRED behavior
 * that does not yet exist in the codebase.
 */

const imeSrc = readFileSync(resolve(__dirname, '../ime.ts'), 'utf-8');

describe('Tab in previewing state commits text (#295)', () => {
  it('keydown handler has a dedicated Tab branch checking _isHolding()', () => {
    // Tab should be intercepted BEFORE the generic KEY_MAP handler when holding
    const tabHolding = imeSrc.match(
      /e\.key\s*===\s*'Tab'[\s\S]*?_isHolding\(\)/,
    );
    expect(
      tabHolding,
      "keydown should check for Tab + _isHolding() to commit before sending '\\t'",
    ).toBeTruthy();
  });

  it('sends ime.value via sendSSHInput before sending Tab char', () => {
    // The handler must call sendSSHInput(text) THEN sendSSHInput('\\t')
    const commitThenTab = imeSrc.match(
      /e\.key\s*===\s*'Tab'[\s\S]*?sendSSHInput\(text\)[\s\S]*?sendSSHInput\('\\t'\)/,
    );
    expect(
      commitThenTab,
      'Tab handler should sendSSHInput(text) then sendSSHInput(\'\\t\')',
    ).toBeTruthy();
  });
});

describe('Tab in previewing state sends Tab char (#295)', () => {
  it("sends '\\t' after committing text", () => {
    // Verify the Tab char is sent as second sendSSHInput call in the Tab branch
    const tabBlock = imeSrc.match(
      /if\s*\(e\.key\s*===\s*'Tab'\)[\s\S]*?sendSSHInput\('\\t'\)/,
    );
    expect(
      tabBlock,
      "Tab branch should include sendSSHInput('\\t')",
    ).toBeTruthy();
  });
});

describe('Tab in previewing state transitions to idle (#295)', () => {
  it('calls _transition(\'idle\') after committing and sending Tab', () => {
    const tabIdle = imeSrc.match(
      /if\s*\(e\.key\s*===\s*'Tab'\)[\s\S]*?_transition\('idle'\)/,
    );
    expect(
      tabIdle,
      "Tab branch should transition to 'idle' after commit",
    ).toBeTruthy();
  });
});

describe('Tab in editing state commits and sends Tab (#295)', () => {
  it('Tab commit applies to both previewing and editing via _isHolding()', () => {
    // _isHolding() returns true for both 'previewing' and 'editing',
    // so the Tab handler should use _isHolding() (not a direct state check)
    const tabHolding = imeSrc.match(
      /e\.key\s*===\s*'Tab'[\s\S]*?_isHolding\(\)\s*&&\s*text/,
    );
    expect(
      tabHolding,
      'Tab handler should guard on _isHolding() && text (covers editing too)',
    ).toBeTruthy();
  });
});

describe('Tab in idle state does nothing special (#295)', () => {
  it('Tab handler only intercepts when holding text, falls through otherwise', () => {
    // The Tab block should have an early return guarded by _isHolding() && text,
    // letting idle-state Tab fall through to the existing KEY_MAP handler
    const guardedReturn = imeSrc.match(
      /if\s*\(e\.key\s*===\s*'Tab'\)\s*\{[^}]*_isHolding\(\)\s*&&\s*text[^}]*return;/s,
    );
    expect(
      guardedReturn,
      'Tab handler should return early only when _isHolding() && text, fall through for idle',
    ).toBeTruthy();
  });
});

describe('Tab records history (#295)', () => {
  it('calls _recordHistory before committing text on Tab', () => {
    const historyBeforeCommit = imeSrc.match(
      /if\s*\(e\.key\s*===\s*'Tab'\)[\s\S]*?_recordHistory\(text\)[\s\S]*?sendSSHInput\(text\)/,
    );
    expect(
      historyBeforeCommit,
      'Tab handler should call _recordHistory(text) before sendSSHInput(text)',
    ).toBeTruthy();
  });
});
