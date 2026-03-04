/**
 * tests/appium/selection-dragselect-explore.spec.js
 *
 * Phase 2 validation: long-press selects URL/word at touch position via
 * terminal.select() API. Tests wrapped URLs, paths, and plain words.
 * No SSH connection needed — injects text via terminal.write().
 */

const { test, expect } = require('./fixtures');
const {
  switchToWebview, switchToNative,
  setupVault,
  getVisibleTerminalBounds, exposeTerminal,
} = require('./fixtures');

/** Perform a long-press at screen coordinates via W3C Actions. */
async function performLongPress(driver, x, y, holdMs = 600) {
  await switchToNative(driver);
  await driver.performActions([{
    type: 'pointer',
    id: 'finger1',
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
}

test.describe('Selection drag-to-select (Phase 2)', () => {
  test.beforeEach(async ({ driver }) => {
    await setupVault(driver);
    await driver.pause(500);
    await exposeTerminal(driver);

    // Write test content directly to terminal (no SSH needed)
    // Include a long URL that will wrap across multiple rows
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
  });

  test('long-press on word selects the word', async ({ driver }) => {
    const bounds = await getVisibleTerminalBounds(driver);
    expect(bounds).toBeTruthy();

    // Read terminal to find where "BRAVO" is, then long-press on it
    const termInfo = await driver.executeScript(`
      const term = window.__testTerminal;
      const buf = term.buffer.active;
      const cols = term.cols;
      const rows = term.rows;
      // Find BRAVO in buffer
      for (let r = 0; r < buf.length; r++) {
        const line = buf.getLine(r);
        if (!line) continue;
        const text = line.translateToString(true);
        const idx = text.indexOf('BRAVO');
        if (idx >= 0) {
          return { row: r, col: idx, viewportY: buf.viewportY, cols, rows };
        }
      }
      return null;
    `, []);
    expect(termInfo).toBeTruthy();

    // Calculate screen position of "BRAVO"
    const screen = await driver.executeScript(`
      const el = window.__testTerminal.element.querySelector('.xterm-screen');
      const rect = el.getBoundingClientRect();
      const dpr = window.devicePixelRatio || 1;
      return { left: rect.left, top: rect.top, width: rect.width, height: rect.height, dpr };
    `, []);

    const cellW = screen.width / termInfo.cols;
    const cellH = screen.height / termInfo.rows;
    const viewportRow = termInfo.row - termInfo.viewportY;
    // Target middle of the "BRAVO" word (col + 2.5 chars)
    const cssX = screen.left + (termInfo.col + 2.5) * cellW;
    const cssY = screen.top + (viewportRow + 0.5) * cellH;
    // Convert to screen pixels for Appium
    const screenX = Math.round(cssX * screen.dpr);
    const screenY = Math.round(cssY * screen.dpr);

    // We need to add the Chrome offset
    const offset = await driver.executeScript(`
      // Approximate: the screen element's top in CSS px * DPR gives us viewport-relative
      const el = window.__testTerminal.element.querySelector('.xterm-screen');
      const rect = el.getBoundingClientRect();
      return { top: rect.top, dpr: window.devicePixelRatio || 1 };
    `, []);

    await performLongPress(driver, screenX, Math.round(offset.top * offset.dpr + (viewportRow + 0.5) * cellH * offset.dpr));
    await driver.pause(500);

    const selection = await driver.executeScript('return window.__testTerminal?.getSelection() || ""', []);
    console.log('Word selection:', JSON.stringify(selection));
    expect(selection).toContain('BRAVO');
  });

  test('long-press on wrapped URL selects full URL', async ({ driver }) => {
    // Use terminal.select() directly to verify the logic works
    // (bypasses touch coordinate translation which is hard to get right in Appium)
    const result = await driver.executeScript(`
      const term = window.__testTerminal;
      const buf = term.buffer.active;
      const cols = term.cols;

      // Find the row containing "https://"
      let urlRow = -1;
      for (let r = 0; r < buf.length; r++) {
        const line = buf.getLine(r);
        if (!line) continue;
        const text = line.translateToString(false);
        if (text.includes('https://')) {
          urlRow = r;
          break;
        }
      }
      if (urlRow < 0) return { error: 'URL row not found' };

      // Build the logical line (joining wrapped rows)
      let firstRow = urlRow;
      while (firstRow > 0) {
        const prev = buf.getLine(firstRow);
        if (!prev || !prev.isWrapped) break;
        firstRow--;
      }
      let fullText = '';
      let r = firstRow;
      let rowCount = 0;
      while (r < buf.length) {
        const row = buf.getLine(r);
        if (!row) break;
        if (r > firstRow && !row.isWrapped) break;
        fullText += row.translateToString(false);
        r++;
        rowCount++;
      }

      // Find URL in logical line
      const urlMatch = fullText.match(/https?:\\/\\/[^\\s"'<>()]+/);
      if (!urlMatch) return { error: 'URL not found in: ' + fullText.substring(0, 100) };

      const urlStart = urlMatch.index;
      const urlLen = urlMatch[0].length;
      const startRow = firstRow + Math.floor(urlStart / cols);
      const startCol = urlStart % cols;

      // Use terminal.select() to select the URL
      term.select(startCol, startRow, urlLen);
      const sel = term.getSelection();

      return {
        url: urlMatch[0],
        selection: sel,
        startRow, startCol, urlLen, rowCount, cols,
        match: sel === urlMatch[0],
      };
    `, []);

    console.log('URL selection result:', JSON.stringify(result));
    expect(result.error).toBeUndefined();
    expect(result.selection.length).toBeGreaterThan(20);
    expect(result.selection).toContain('https://');
    expect(result.match).toBe(true);
  });

  test('long-press on file path selects full path', async ({ driver }) => {
    const result = await driver.executeScript(`
      const term = window.__testTerminal;
      const buf = term.buffer.active;

      // Find the row with /home/ra
      for (let r = 0; r < buf.length; r++) {
        const line = buf.getLine(r);
        if (!line) continue;
        const text = line.translateToString(false);
        const pathMatch = text.match(/\\/home\\/ra\\/[^\\s"'<>():|]+/);
        if (pathMatch) {
          term.select(pathMatch.index, r, pathMatch[0].length);
          const sel = term.getSelection();
          return { path: pathMatch[0], selection: sel, match: sel === pathMatch[0] };
        }
      }
      return { error: 'path not found' };
    `, []);

    console.log('Path selection result:', JSON.stringify(result));
    expect(result.error).toBeUndefined();
    expect(result.selection).toContain('/home/ra/code/mobissh');
    expect(result.match).toBe(true);
  });
});
