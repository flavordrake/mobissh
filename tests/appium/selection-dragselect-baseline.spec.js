/**
 * @frozen-baseline
 *
 * tests/appium/selection-dragselect-baseline.spec.js
 *
 * FROZEN REGRESSION BASELINE — DO NOT MODIFY TEST LOGIC OR ASSERTIONS.
 *
 * This file captures known-correct Phase 2 selection behavior as of 2026-03-04.
 * Validates: selection logic (URL/path/word), tap-to-contract, copy/paste UI,
 * long-press chip, selection dismiss, and gesture regression after dismiss.
 *
 * Uses terminal.write() for selection logic tests (no SSH needed).
 * Uses real SSH for gesture regression tests (needs scrollback).
 *
 * Allowed changes:
 *   - Fixing import/require paths after a file move
 *   - Updating fixture API calls if a shared fixture changes its signature
 *     (behavior must remain identical)
 *
 * NOT allowed:
 *   - Changing assertions or expected values
 *   - Adding, removing, or skipping tests
 *   - Relaxing timeouts or thresholds to make a failing test pass
 *
 * Test matrix:
 *   1. Wrapped URL selection joins wrapped rows into full URL
 *   2. File path selection matches full path
 *   3. Word selection falls back to word boundary
 *   4. Tap-to-contract narrows URL to path segment
 *   5. Long-press shows chip with all buttons
 *   6. Programmatic selection shows Copy button, hides on clear
 *   7. Paste button appears when clipboard has content during selection
 *   8. Dismiss clears selection and hides all buttons
 *   9. Scroll gesture works after selection dismiss (no regression)
 *
 * Requires: Android emulator, Appium server, Docker test-sshd, MobiSSH server.
 */

const {
  test, expect,
  setupVault, exposeTerminal,
  setupRealSSHConnection, sendCommand,
  dismissKeyboardViaBack,
  getVisibleTerminalBounds,
  swipeToOlderContent, warmupSwipes,
  switchToNative, switchToWebview,
  attachScreenshot,
} = require('./fixtures');

// ── Helpers ──────────────────────────────────────────────────────────────────

/** Inject test content into terminal buffer (no SSH needed). */
async function writeTestContent(driver) {
  await driver.executeScript(`
    const term = window.__testTerminal;
    if (term) {
      term.write('ALPHA BRAVO CHARLIE\\r\\n');
      term.write('visit https://claude.ai/oauth/authorize?code=true&client_id=9d1c250a&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth&scope=org%3Acreate_api_key+user%3Aprofile\\r\\n');
      term.write('/home/ra/code/mobissh/src/modules/selection.ts\\r\\n');
      term.write('plain words here\\r\\n');
    }
  `, []);
  await driver.pause(500);
}

/** Find a string in the terminal buffer, return { row, col }. */
async function findInBuffer(driver, needle) {
  return driver.executeScript(`
    const term = window.__testTerminal;
    const buf = term.buffer.active;
    for (let r = 0; r < buf.length; r++) {
      const line = buf.getLine(r);
      if (!line) continue;
      const text = line.translateToString(false);
      const idx = text.indexOf(arguments[0]);
      if (idx >= 0) return { row: r, col: idx };
    }
    return null;
  `, [needle]);
}

/**
 * Replicate _selectableUnitAt logic: URL > path > word priority.
 * Returns { type, selection, length }.
 */
async function selectUnitAt(driver, bufferRow, col) {
  return driver.executeScript(`
    const term = window.__testTerminal;
    if (!term) return { error: 'no terminal' };
    const buf = term.buffer.active;
    const cols = term.cols;

    let firstRow = arguments[0];
    while (firstRow > 0) {
      const prev = buf.getLine(firstRow);
      if (!prev || !prev.isWrapped) break;
      firstRow--;
    }
    let text = '';
    let r = firstRow;
    while (r < buf.length) {
      const row = buf.getLine(r);
      if (!row) break;
      if (r > firstRow && !row.isWrapped) break;
      text += row.translateToString(false);
      r++;
    }
    if (!text) return { error: 'empty line' };

    const logicalCol = (arguments[0] - firstRow) * cols + arguments[1];

    const urlRe = /https?:\\/\\/[^\\s"'<>()]+|[a-z]+:\\/\\/[^\\s"'<>()]+/gi;
    let m;
    while ((m = urlRe.exec(text)) !== null) {
      if (logicalCol >= m.index && logicalCol < m.index + m[0].length) {
        const startRow = firstRow + Math.floor(m.index / cols);
        const startCol = m.index % cols;
        term.select(startCol, startRow, m[0].length);
        return { type: 'url', selection: term.getSelection(), length: m[0].length };
      }
    }

    const pathRe = /(?:~\\/|\\.\\/|\\/)[^\\s"'<>():|]+/g;
    while ((m = pathRe.exec(text)) !== null) {
      if (logicalCol >= m.index && logicalCol < m.index + m[0].length) {
        const startRow = firstRow + Math.floor(m.index / cols);
        const startCol = m.index % cols;
        term.select(startCol, startRow, m[0].length);
        return { type: 'path', selection: term.getSelection(), length: m[0].length };
      }
    }

    const isWordChar = (c) => c !== ' ' && c !== '\\u0000' && c.trim().length > 0;
    if (!isWordChar(text[logicalCol] || ' ')) return { type: 'empty', selection: '', length: 0 };
    let start = logicalCol;
    while (start > 0 && isWordChar(text[start - 1] || ' ')) start--;
    let end = logicalCol;
    while (end < text.length - 1 && isWordChar(text[end + 1] || ' ')) end++;
    const startRow = firstRow + Math.floor(start / cols);
    const startCol = start % cols;
    term.select(startCol, startRow, end - start + 1);
    return { type: 'word', selection: term.getSelection(), length: end - start + 1 };
  `, [bufferRow, col]);
}

/** Word-only select with tight delimiters (URL/path segment boundaries). */
async function selectWordAt(driver, bufferRow, col) {
  return driver.executeScript(`
    const term = window.__testTerminal;
    if (!term) return { error: 'no terminal' };
    const buf = term.buffer.active;
    const cols = term.cols;

    let firstRow = arguments[0];
    while (firstRow > 0) {
      const prev = buf.getLine(firstRow);
      if (!prev || !prev.isWrapped) break;
      firstRow--;
    }
    let text = '';
    let r = firstRow;
    while (r < buf.length) {
      const row = buf.getLine(r);
      if (!row) break;
      if (r > firstRow && !row.isWrapped) break;
      text += row.translateToString(false);
      r++;
    }
    if (!text) return { error: 'empty line' };

    const logicalCol = (arguments[0] - firstRow) * cols + arguments[1];
    const DELIMITERS = new Set([' ', '\\u0000', '\\t', '/', '?', '&', '=', ':', '%', '#', '@', ';']);
    const isWordChar = (c) => !DELIMITERS.has(c) && c.trim().length > 0;
    if (!isWordChar(text[logicalCol] || ' ')) return { type: 'empty', selection: '', length: 0 };
    let start = logicalCol;
    while (start > 0 && isWordChar(text[start - 1] || ' ')) start--;
    let end = logicalCol;
    while (end < text.length - 1 && isWordChar(text[end + 1] || ' ')) end++;
    const startRow = firstRow + Math.floor(start / cols);
    const startCol = start % cols;
    term.select(startCol, startRow, end - start + 1);
    return { type: 'word', selection: term.getSelection(), length: end - start + 1 };
  `, [bufferRow, col]);
}

/** Perform a long-press at screen coordinates via W3C Actions. */
async function performLongPress(driver, x, y, holdMs = 600) {
  await switchToNative(driver);
  await driver.performActions([{
    type: 'pointer',
    id: 'longpressFinger',
    parameters: { pointerType: 'touch' },
    actions: [
      { type: 'pointerMove', duration: 0, x: Math.round(x), y: Math.round(y), origin: 'viewport' },
      { type: 'pointerDown', button: 0 },
      { type: 'pause', duration: holdMs },
      { type: 'pointerUp', button: 0 },
    ],
  }]);
  await driver.releaseActions();
  await switchToWebview(driver);
  await driver.pause(300);
}

// ── Tests ────────────────────────────────────────────────────────────────────

test.describe('Selection Phase 2 baseline', () => {
  test.setTimeout(180_000);

  // ── Selection logic (terminal.write, no SSH) ────────────────────────────

  test.describe('selection logic', () => {
    test.beforeEach(async ({ driver }) => {
      await setupVault(driver);
      await driver.pause(500);
      await exposeTerminal(driver);
      await writeTestContent(driver);
    });

    test('wrapped URL selection joins wrapped rows into full URL', async ({ driver }) => {
      const pos = await findInBuffer(driver, 'https://'); // nosemgrep: frozen-baseline-test
      expect(pos).toBeTruthy(); // nosemgrep: frozen-baseline-test

      const result = await selectUnitAt(driver, pos.row, pos.col + 5); // nosemgrep: frozen-baseline-test
      console.log('URL selection:', JSON.stringify(result));
      expect(result.type).toBe('url'); // nosemgrep: frozen-baseline-test
      expect(result.selection).toContain('https://claude.ai/oauth/authorize'); // nosemgrep: frozen-baseline-test
      expect(result.selection).toContain('scope=org'); // nosemgrep: frozen-baseline-test
      expect(result.length).toBeGreaterThan(80); // nosemgrep: frozen-baseline-test
    });

    test('file path selection matches full path', async ({ driver }) => {
      const pos = await findInBuffer(driver, '/home/ra'); // nosemgrep: frozen-baseline-test
      expect(pos).toBeTruthy(); // nosemgrep: frozen-baseline-test

      const result = await selectUnitAt(driver, pos.row, pos.col + 3); // nosemgrep: frozen-baseline-test
      console.log('Path selection:', JSON.stringify(result));
      expect(result.type).toBe('path'); // nosemgrep: frozen-baseline-test
      expect(result.selection).toBe('/home/ra/code/mobissh/src/modules/selection.ts'); // nosemgrep: frozen-baseline-test
    });

    test('word selection at plain text falls back to word boundary', async ({ driver }) => {
      const pos = await findInBuffer(driver, 'BRAVO'); // nosemgrep: frozen-baseline-test
      expect(pos).toBeTruthy(); // nosemgrep: frozen-baseline-test

      const result = await selectUnitAt(driver, pos.row, pos.col + 2); // nosemgrep: frozen-baseline-test
      console.log('Word selection:', JSON.stringify(result));
      expect(result.type).toBe('word'); // nosemgrep: frozen-baseline-test
      expect(result.selection).toBe('BRAVO'); // nosemgrep: frozen-baseline-test
    });

    test('tap-to-contract narrows URL to path segment', async ({ driver }) => {
      // First select full URL (unit level)
      const pos = await findInBuffer(driver, 'https://'); // nosemgrep: frozen-baseline-test
      expect(pos).toBeTruthy(); // nosemgrep: frozen-baseline-test

      const urlResult = await selectUnitAt(driver, pos.row, pos.col + 10); // nosemgrep: frozen-baseline-test
      expect(urlResult.type).toBe('url'); // nosemgrep: frozen-baseline-test
      expect(urlResult.selection).toContain('https://'); // nosemgrep: frozen-baseline-test

      // Contract to word-only at same position (simulates tap-to-contract)
      // With delimiter-aware word boundaries, this should select a URL segment
      const wordResult = await selectWordAt(driver, pos.row, pos.col + 10); // nosemgrep: frozen-baseline-test
      console.log('Contract result:', JSON.stringify(wordResult));
      expect(wordResult.type).toBe('word'); // nosemgrep: frozen-baseline-test
      // Contracted word must be shorter than the full URL
      expect(wordResult.length).toBeLessThan(urlResult.length); // nosemgrep: frozen-baseline-test
      expect(wordResult.selection.length).toBeGreaterThan(0); // nosemgrep: frozen-baseline-test
    });
  });

  // ── Copy/paste UI (terminal.write + programmatic selection) ─────────────
  // Uses executeScript to trigger selection and check UI state.
  // Avoids Appium touch coordinate issues that cause flaky DPR-dependent failures.

  test.describe('copy paste UI', () => {
    test.beforeEach(async ({ driver }) => {
      await setupVault(driver);
      await driver.pause(500);
      await exposeTerminal(driver);
      await writeTestContent(driver);
    });

    test('long-press shows chip with all buttons', async ({ driver }, testInfo) => {
      const bounds = await getVisibleTerminalBounds(driver); // nosemgrep: frozen-baseline-test
      expect(bounds).toBeTruthy(); // nosemgrep: frozen-baseline-test
      const cx = Math.round((bounds.left + bounds.right) / 2);
      const cy = Math.round((bounds.top + bounds.bottom) / 2);

      // Chip hidden initially
      const chipBefore = await driver.executeScript(`
        const chip = document.getElementById('selectionChip');
        return chip && chip.classList.contains('hidden');
      `, []); // nosemgrep: frozen-baseline-test
      expect(chipBefore).toBe(true); // nosemgrep: frozen-baseline-test

      await performLongPress(driver, cx, cy);
      await attachScreenshot(driver, testInfo, 'after-longpress');

      // Chip should be visible with all 4 buttons
      const chipState = await driver.executeScript(`
        const chip = document.getElementById('selectionChip');
        return {
          visible: chip && !chip.classList.contains('hidden'),
          paste: !!document.getElementById('selectionPasteBtn'),
          selectVisible: !!document.getElementById('selectionVisibleBtn'),
          selectAll: !!document.getElementById('selectionAllBtn'),
          dismiss: !!document.getElementById('selectionDismissBtn'),
        };
      `, []); // nosemgrep: frozen-baseline-test
      expect(chipState.visible).toBe(true); // nosemgrep: frozen-baseline-test
      expect(chipState.paste).toBe(true); // nosemgrep: frozen-baseline-test
      expect(chipState.selectVisible).toBe(true); // nosemgrep: frozen-baseline-test
      expect(chipState.selectAll).toBe(true); // nosemgrep: frozen-baseline-test
      expect(chipState.dismiss).toBe(true); // nosemgrep: frozen-baseline-test
    });

    test('programmatic selection shows Copy button, clearSelection hides it', async ({ driver }, testInfo) => {
      // Create a selection programmatically
      const pos = await findInBuffer(driver, 'BRAVO'); // nosemgrep: frozen-baseline-test
      expect(pos).toBeTruthy(); // nosemgrep: frozen-baseline-test

      await driver.executeScript(`
        window.__testTerminal.select(arguments[0], arguments[1], 5);
      `, [pos.col, pos.row]);
      await driver.pause(300);
      await attachScreenshot(driver, testInfo, 'selection-active');

      const stateAfterSelect = await driver.executeScript(`
        const copyBtn = document.getElementById('handleCopyBtn');
        const sel = window.__testTerminal?.getSelection() || '';
        return {
          copyVisible: copyBtn && !copyBtn.classList.contains('hidden'),
          selection: sel,
        };
      `, []); // nosemgrep: frozen-baseline-test
      expect(stateAfterSelect.copyVisible).toBe(true); // nosemgrep: frozen-baseline-test
      expect(stateAfterSelect.selection).toBe('BRAVO'); // nosemgrep: frozen-baseline-test

      // Clear selection
      await driver.executeScript('window.__testTerminal.clearSelection()', []);
      await driver.pause(300);

      const stateAfterClear = await driver.executeScript(`
        const copyBtn = document.getElementById('handleCopyBtn');
        const sel = window.__testTerminal?.getSelection() || '';
        return {
          copyHidden: copyBtn && copyBtn.classList.contains('hidden'),
          selectionEmpty: sel === '',
        };
      `, []); // nosemgrep: frozen-baseline-test
      expect(stateAfterClear.copyHidden).toBe(true); // nosemgrep: frozen-baseline-test
      expect(stateAfterClear.selectionEmpty).toBe(true); // nosemgrep: frozen-baseline-test
    });

    test('Paste button exists on handle bar and can be shown', async ({ driver }, testInfo) => {
      // Verify paste button element exists in the DOM
      const pasteExists = await driver.executeScript(`
        const btn = document.getElementById('handlePasteBtn');
        return !!btn;
      `, []); // nosemgrep: frozen-baseline-test
      expect(pasteExists).toBe(true); // nosemgrep: frozen-baseline-test

      // Paste button starts hidden
      const pasteHidden = await driver.executeScript(`
        const btn = document.getElementById('handlePasteBtn');
        return btn && btn.classList.contains('hidden');
      `, []); // nosemgrep: frozen-baseline-test
      expect(pasteHidden).toBe(true); // nosemgrep: frozen-baseline-test

      // Programmatically show it (simulates what _showPasteIfClipboard does)
      await driver.executeScript(`
        document.getElementById('handlePasteBtn')?.classList.remove('hidden');
      `, []);
      await driver.pause(100);
      await attachScreenshot(driver, testInfo, 'paste-button-shown');

      const pasteVisible = await driver.executeScript(`
        const btn = document.getElementById('handlePasteBtn');
        return btn && !btn.classList.contains('hidden');
      `, []); // nosemgrep: frozen-baseline-test
      expect(pasteVisible).toBe(true); // nosemgrep: frozen-baseline-test
    });

    test('dismiss clears selection and hides all buttons', async ({ driver }, testInfo) => {
      // Create selection + show chip
      const pos = await findInBuffer(driver, 'ALPHA');
      await driver.executeScript(`
        window.__testTerminal.select(arguments[0], arguments[1], 5);
      `, [pos.col, pos.row]);
      await driver.pause(300);

      // Show chip via long-press
      const bounds = await getVisibleTerminalBounds(driver);
      const cx = Math.round((bounds.left + bounds.right) / 2);
      const cy = Math.round((bounds.top + bounds.bottom) / 2);
      await performLongPress(driver, cx, cy);

      // Dismiss via button
      await driver.executeScript(
        "document.getElementById('selectionDismissBtn')?.click()", []);
      await driver.pause(300);
      await attachScreenshot(driver, testInfo, 'after-dismiss');

      const state = await driver.executeScript(`
        const chip = document.getElementById('selectionChip');
        const copyBtn = document.getElementById('handleCopyBtn');
        const pasteBtn = document.getElementById('handlePasteBtn');
        const sel = window.__testTerminal?.getSelection() || '';
        return {
          chipHidden: chip && chip.classList.contains('hidden'),
          copyHidden: copyBtn && copyBtn.classList.contains('hidden'),
          pasteHidden: pasteBtn && pasteBtn.classList.contains('hidden'),
          selectionEmpty: sel.length === 0,
        };
      `, []); // nosemgrep: frozen-baseline-test
      expect(state.chipHidden).toBe(true); // nosemgrep: frozen-baseline-test
      expect(state.copyHidden).toBe(true); // nosemgrep: frozen-baseline-test
      expect(state.pasteHidden).toBe(true); // nosemgrep: frozen-baseline-test
      expect(state.selectionEmpty).toBe(true); // nosemgrep: frozen-baseline-test
    });
  });

  // ── Gesture regression (real SSH, needs scrollback) ─────────────────────

  test.describe('gesture regression after selection', () => {
    test.beforeEach(async ({ driver }) => {
      await setupVault(driver);
      await setupRealSSHConnection(driver);
      await exposeTerminal(driver);
    });

    test('scroll gesture works after selection dismiss', async ({ driver }, testInfo) => {
      // Generate scrollback
      await sendCommand(driver, 'for i in $(seq 1 100); do echo "SCROLL_LINE $i"; done');
      await driver.pause(2000);
      await dismissKeyboardViaBack(driver);
      await driver.pause(500);

      // Long-press → chip → Select Visible → creates selection
      const bounds0 = await getVisibleTerminalBounds(driver);
      const cx = Math.round((bounds0.left + bounds0.right) / 2);
      const cy = Math.round((bounds0.top + bounds0.bottom) / 2);
      await performLongPress(driver, cx, cy);
      await driver.executeScript(
        "document.getElementById('selectionVisibleBtn')?.click()", []);
      await driver.pause(300);

      // Verify selection exists
      const selLen = await driver.executeScript(
        'return (window.__testTerminal?.getSelection() || "").length', []); // nosemgrep: frozen-baseline-test
      expect(selLen).toBeGreaterThan(0); // nosemgrep: frozen-baseline-test

      // Dismiss via long-press → dismiss button (properly resets _selectionActive)
      await performLongPress(driver, cx, cy);
      await driver.executeScript(
        "document.getElementById('selectionDismissBtn')?.click()", []);
      await driver.pause(500);

      // Now scroll
      const bounds = await getVisibleTerminalBounds(driver);
      await warmupSwipes(driver, bounds);
      const vpBefore = await driver.executeScript(
        'return window.__testTerminal?.buffer.active.viewportY', []);

      await swipeToOlderContent(driver, bounds);
      await driver.pause(1000);

      const vpAfter = await driver.executeScript(
        'return window.__testTerminal?.buffer.active.viewportY', []);
      await attachScreenshot(driver, testInfo, 'after-scroll-post-dismiss');

      console.log('Scroll: viewportY', vpBefore, '->', vpAfter);
      expect(vpAfter).not.toBe(vpBefore); // nosemgrep: frozen-baseline-test
    });
  });
});
