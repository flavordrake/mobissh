import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

/**
 * Keybar → IME preview routing tests (#274).
 *
 * When the IME preview textarea is visible, keybar buttons should route
 * intelligently instead of blindly inserting escape sequences:
 *   - Arrow keys: move cursor in textarea (no escape sequence insertion)
 *   - Backspace: delete char before cursor (no sendSSHInput)
 *   - Enter: commit preview text then send \r
 *   - Ctrl+key: bypass preview, send to terminal
 *   - Other printable keys: insert into textarea at cursor
 *   - When preview NOT visible: all keys go to terminal
 *   - Escape: dismiss preview (transition to idle)
 *
 * These are TDD red-baseline tests — they describe DESIRED behavior
 * that does not yet exist. The current code inserts raw escape sequences
 * into the textarea for arrows/backspace, which is the bug.
 */

const uiSrc = readFileSync(resolve(__dirname, '../ui.ts'), 'utf-8');

// Extract the keybar handler block (the for...of loop over keys entries)
const handlerBlock = uiSrc.match(
  /for\s*\(const\s*\[id,\s*seq\]\s*of\s*Object\.entries\(keys\)\)[\s\S]*?_attachRepeat\([\s\S]*?\n {2}\}/,
)?.[0] ?? '';

describe('Arrow keys move cursor in textarea, do not insert escape sequences (#274)', () => {
  it('handler distinguishes arrow keys from other keys when preview is visible', () => {
    // The handler should check if `seq` is an arrow escape sequence and
    // manipulate selectionStart/selectionEnd instead of inserting into value
    const arrowBranch = handlerBlock.match(
      /\\x1b\[([ABCD])[\s\S]*?selectionStart(?![\s\S]*?slice[\s\S]*?seq)/,
    );
    expect(
      arrowBranch,
      'Arrow keys should move cursor via selectionStart/End, not insert seq into value',
    ).toBeTruthy();
  });

  it('arrow keys do not call sendSSHInput when preview is visible', () => {
    // When preview is visible AND key is an arrow, sendSSHInput must NOT be called.
    // The current code routes to textarea but inserts the escape seq — need a
    // branch that adjusts cursor position only.
    const arrowGuard = handlerBlock.match(
      /(?:isArrow|arrow|ARROW|\\x1b\[[ABCD])[\s\S]*?(?:selectionStart\s*[-+]=|selectionStart\s*=\s*(?:start|sel)[\s\S]*?[-+])/,
    );
    expect(
      arrowGuard,
      'Arrow key handler should adjust selectionStart/End without inserting text',
    ).toBeTruthy();
  });

  it('left arrow decrements selectionStart', () => {
    // For left arrow (\x1b[D), handler should do: ime.selectionStart = Math.max(0, start - 1)
    const leftArrow = handlerBlock.match(
      /\\x1b\[D[\s\S]*?(?:start\s*-\s*1|selectionStart\s*-=\s*1|Math\.max\(0)/,
    ) ?? handlerBlock.match(
      /(?:left|LEFT|isLeft)[\s\S]*?(?:start\s*-\s*1|selectionStart\s*-=\s*1)/,
    );
    expect(
      leftArrow,
      'Left arrow should decrement cursor position',
    ).toBeTruthy();
  });

  it('right arrow increments selectionStart', () => {
    // For right arrow (\x1b[C), handler should do: ime.selectionStart = Math.min(len, start + 1)
    const rightArrow = handlerBlock.match(
      /\\x1b\[C[\s\S]*?(?:start\s*\+\s*1|selectionStart\s*\+=\s*1|Math\.min)/,
    ) ?? handlerBlock.match(
      /(?:right|RIGHT|isRight)[\s\S]*?(?:start\s*\+\s*1|selectionStart\s*\+=\s*1)/,
    );
    expect(
      rightArrow,
      'Right arrow should increment cursor position',
    ).toBeTruthy();
  });

  it('does not insert escape sequence text into ime.value for arrows', () => {
    // The current buggy code does: ime.value = ...slice(0,start) + seq + slice(end)
    // for ALL keys including arrows. The fix must NOT insert arrow seqs into value.
    // Check that the handler has a guard that prevents inserting arrow seqs.
    const noArrowInsert = handlerBlock.match(
      /(?:isArrow|ARROW_SEQS|arrowKeys)[\s\S]*?(?:return|continue|break|selectionStart)/,
    );
    expect(
      noArrowInsert,
      'Handler must guard against inserting arrow escape sequences into textarea value',
    ).toBeTruthy();
  });
});

describe('Backspace deletes char before cursor in textarea (#274)', () => {
  it('handler has a backspace branch that removes character before cursor', () => {
    // Backspace (\x7f or \b) should: ime.value = slice(0, start-1) + slice(end)
    // instead of inserting the backspace char into the textarea
    const backspaceBranch = handlerBlock.match(
      /(?:backspace|Backspace|\\x7f|\\x08|BACKSPACE)[\s\S]*?slice\(0,\s*(?:start|sel)\s*-\s*1\)/,
    ) ?? handlerBlock.match(
      /(?:backspace|Backspace|\\x7f|\\x08)[\s\S]*?(?:deleteContent|value\s*=)/,
    );
    expect(
      backspaceBranch,
      'Backspace should delete character before cursor, not insert \\x7f into value',
    ).toBeTruthy();
  });

  it('backspace does not call sendSSHInput when preview is visible', () => {
    // Verify that the backspace path in the preview-visible branch does NOT
    // fall through to sendSSHInput
    const bsNoSend = handlerBlock.match(
      /(?:backspace|\\x7f|\\x08)[\s\S]*?(?:return|continue|break)[\s\S]*?sendSSHInput/,
    ) ?? handlerBlock.match(
      /(?:backspace|\\x7f)[\s\S]*?(?:value\s*=)[\s\S]*?(?:return|selectionStart)/,
    );
    expect(
      bsNoSend,
      'Backspace in preview mode should not call sendSSHInput',
    ).toBeTruthy();
  });
});

describe('Enter commits preview text (#274)', () => {
  it('handler has an Enter branch that calls sendSSHInput with textarea value', () => {
    // Enter (\r or \n) should: sendSSHInput(ime.value), sendSSHInput('\r'), transition to idle
    const enterCommit = handlerBlock.match(
      /(?:enter|Enter|\\r|\\n|ENTER)[\s\S]*?sendSSHInput\([\s\S]*?(?:ime\.value|text|value)/,
    );
    expect(
      enterCommit,
      'Enter should commit preview text via sendSSHInput(ime.value)',
    ).toBeTruthy();
  });

  it('Enter sends carriage return after committing text', () => {
    const enterCR = handlerBlock.match(
      /(?:enter|Enter|ENTER)[\s\S]*?sendSSHInput\([\s\S]*?\\r/,
    );
    expect(
      enterCR,
      "Enter should send '\\r' after committing text",
    ).toBeTruthy();
  });

  it('Enter transitions to idle after committing', () => {
    const enterIdle = handlerBlock.match(
      /(?:enter|Enter|ENTER)[\s\S]*?(?:_transition\(['"]idle['"]\)|clearIMEPreview|_imeState\s*=\s*['"]idle)/,
    );
    expect(
      enterIdle,
      'Enter should transition IME to idle after committing',
    ).toBeTruthy();
  });
});

describe('Ctrl+key bypasses preview, sends to terminal (#274)', () => {
  it('handler checks ctrlActive and routes to sendSSHInput', () => {
    // When appState.ctrlActive is true, keys should bypass preview
    // and go directly to sendSSHInput even when preview is visible
    const ctrlBypass = handlerBlock.match(
      /ctrlActive[\s\S]*?sendSSHInput/,
    );
    expect(
      ctrlBypass,
      'Ctrl+key should bypass preview and call sendSSHInput directly',
    ).toBeTruthy();
  });

  it('ctrl check occurs before the preview-visible branch', () => {
    // The ctrlActive check must come BEFORE the ime-visible check,
    // so Ctrl+C always goes to terminal even during preview
    const ctrlBeforeIme = handlerBlock.match(
      /ctrlActive[\s\S]*?(?:sendSSHInput|return)[\s\S]*?ime-visible/,
    );
    expect(
      ctrlBeforeIme,
      'ctrlActive check should precede the preview-visible branch',
    ).toBeTruthy();
  });
});

describe('Other printable keys insert into textarea at cursor (#274)', () => {
  it('printable keys still insert into textarea value when preview is visible', () => {
    // Non-special keys (letters, numbers, symbols) should insert at cursor.
    // This is what the current code does for ALL keys — the fix should
    // preserve this for printable keys while fixing arrows/backspace/enter.
    const insertLogic = handlerBlock.match(
      /ime\.value\s*=\s*ime\.value\.slice\(0,\s*start\)\s*\+\s*seq\s*\+\s*ime\.value\.slice/,
    );
    // This SHOULD still exist for printable keys (the default branch)
    expect(
      insertLogic,
      'Printable keys should still insert at cursor position in textarea',
    ).toBeTruthy();
  });
});

describe('When preview NOT visible, all keys go to terminal (#274)', () => {
  it('else branch calls sendSSHInput when ime is not visible', () => {
    // The existing else branch: sendSSHInput(seq)
    const elseBranch = handlerBlock.match(
      /}\s*else\s*\{[\s\S]*?sendSSHInput\(seq\)/,
    );
    expect(
      elseBranch,
      'When preview is not visible, keys should go to sendSSHInput(seq)',
    ).toBeTruthy();
  });

  it('check includes ime-visible class test', () => {
    const visibleCheck = handlerBlock.match(
      /classList\.contains\(['"]ime-visible['"]\)/,
    );
    expect(
      visibleCheck,
      'Handler should check for ime-visible class to determine preview state',
    ).toBeTruthy();
  });
});

describe('Escape dismisses preview (#274)', () => {
  it('handler has an Escape/Esc branch that transitions to idle', () => {
    // Esc (\x1b) when preview visible should dismiss the preview
    // instead of sending Esc to the terminal
    const escBranch = handlerBlock.match(
      /(?:esc|Esc|ESC|\\x1b(?!\[))[\s\S]*?(?:_transition\(['"]idle['"]\)|clearIMEPreview|dismiss)/,
    ) ?? handlerBlock.match(
      /(?:isEsc|seq\s*===\s*'\\x1b')[\s\S]*?(?:idle|clear|dismiss)/,
    );
    expect(
      escBranch,
      'Escape key should dismiss preview (transition to idle), not send to terminal',
    ).toBeTruthy();
  });

  it('Escape does not send to terminal when preview is visible', () => {
    // Esc should NOT call sendSSHInput when preview is active
    const escNoSend = handlerBlock.match(
      /(?:esc|Esc|\\x1b(?!\[))[\s\S]*?(?:return|continue|break)[\s\S]*?(?:sendSSHInput)/,
    );
    expect(
      escNoSend,
      'Escape in preview mode should not call sendSSHInput',
    ).toBeTruthy();
  });
});

describe('Edge cases (#274)', () => {
  it('empty textarea with preview visible still checks key routing', () => {
    // The current code has `&& ime.value` which skips routing when textarea is empty.
    // When preview is visible but empty, arrows/enter/esc should still be routed
    // to preview logic, not to terminal.
    // The fix should check ime-visible regardless of ime.value for control keys.
    const emptyCheck = handlerBlock.match(
      /ime-visible[\s\S]*?(?:!ime\.value|ime\.value\s*===\s*['"]|\.length\s*===\s*0)[\s\S]*?(?:esc|arrow|Enter)/i,
    ) ?? handlerBlock.match(
      // At minimum: the ime.value check should be separate from the ime-visible check
      // so that Esc/arrows work even with empty textarea
      /classList\.contains\(['"]ime-visible['"]\)(?!\s*&&\s*ime\.value)/,
    );
    expect(
      emptyCheck,
      'Preview routing should not require ime.value to be non-empty for control keys (Esc, arrows)',
    ).toBeTruthy();
  });
});
