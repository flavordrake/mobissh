/**
 * @frozen-baseline
 *
 * tests/appium/selection-longpress-baseline.spec.js
 *
 * FROZEN REGRESSION BASELINE — DO NOT MODIFY TEST LOGIC OR ASSERTIONS.
 *
 * This file captures known-correct long-press selection behavior as of 2026-03-04.
 * It exists to catch regressions when selection features are developed further.
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
 * To test new selection features (drag-to-select, buffer modal), create a new
 * spec file. See CLAUDE.md "Test Layering Policy" for the full policy.
 *
 * Regression baseline: long-press selection chip via Appium W3C Actions.
 *
 * Test matrix:
 *   1. Long-press shows selection chip with Paste, Select Visible, Select All, ✕
 *   2. Dismiss button (✕) hides chip and restores gesture control
 *   3. Select Visible selects visible terminal rows, Copy button appears
 *   4. Select All selects entire buffer, Copy button appears
 *   5. Scroll gesture still works after selection dismiss (no regression)
 *
 * Requires: Android emulator, Appium server, Docker test-sshd, MobiSSH server.
 */

const {
  test, expect,
  setupRealSSHConnection, setupVault, sendCommand,
  dismissKeyboardViaBack, exposeTerminal,
  getVisibleTerminalBounds,
  swipeToOlderContent, warmupSwipes,
  readScreen, attachScreenshot,
  switchToNative, switchToWebview,
  dismissNativeDialogs,
  BASE_URL,
} = require('./fixtures');

/**
 * Perform a long-press at the given screen coordinates.
 * Uses W3C Actions: pointerDown, pause 600ms, pointerUp.
 */
async function performLongPress(driver, x, y) {
  await switchToNative(driver);
  await driver.performActions([{
    type: 'pointer',
    id: 'longpressFinger',
    parameters: { pointerType: 'touch' },
    actions: [
      { type: 'pointerMove', duration: 0, x: Math.round(x), y: Math.round(y), origin: 'viewport' },
      { type: 'pointerDown', button: 0 },
      { type: 'pause', duration: 600 },
      { type: 'pointerUp', button: 0 },
    ],
  }]);
  await driver.releaseActions();
  await switchToWebview(driver);
  await driver.pause(300);
}

test.describe('Selection long-press baseline (Appium)', () => {
  test.setTimeout(180_000);

  test.beforeEach(async ({ driver }) => {
    await driver.executeScript('localStorage.clear()', []);
    await driver.url(BASE_URL);
    await driver.pause(2000);
    await dismissNativeDialogs(driver);
    await switchToWebview(driver);
    await setupVault(driver);
    await driver.executeScript(
      "document.querySelector('[data-panel=\"terminal\"]')?.click()", []);
    await driver.pause(500);
  });

  test('long-press shows selection chip with correct buttons', async ({ driver }, testInfo) => {
    await setupRealSSHConnection(driver);
    await exposeTerminal(driver);
    await dismissKeyboardViaBack(driver);
    await driver.pause(500);

    // Verify chip is hidden initially
    const chipHidden = await driver.executeScript(`
      const chip = document.getElementById('selectionChip');
      return chip && chip.classList.contains('hidden');
    `, []); // nosemgrep: frozen-baseline-test
    expect(chipHidden).toBe(true); // nosemgrep: frozen-baseline-test

    // Long-press in the center of the terminal
    const bounds = await getVisibleTerminalBounds(driver);
    expect(bounds).not.toBeNull(); // nosemgrep: frozen-baseline-test
    const cx = Math.round((bounds.left + bounds.right) / 2);
    const cy = Math.round((bounds.top + bounds.bottom) / 2);
    await performLongPress(driver, cx, cy);

    await attachScreenshot(driver, testInfo, 'after-longpress');

    // Verify chip is visible with all buttons
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

  test('dismiss button hides chip and restores gesture control', async ({ driver }, testInfo) => {
    await setupRealSSHConnection(driver);
    await exposeTerminal(driver);
    await dismissKeyboardViaBack(driver);
    await driver.pause(500);

    // Long-press to show chip
    const bounds = await getVisibleTerminalBounds(driver);
    const cx = Math.round((bounds.left + bounds.right) / 2);
    const cy = Math.round((bounds.top + bounds.bottom) / 2);
    await performLongPress(driver, cx, cy);

    // Tap dismiss button
    await driver.executeScript(
      "document.getElementById('selectionDismissBtn')?.click()", []);
    await driver.pause(300);

    await attachScreenshot(driver, testInfo, 'after-dismiss');

    // Verify chip is hidden and selection is inactive
    const state = await driver.executeScript(`
      const chip = document.getElementById('selectionChip');
      const { isSelectionActive } = await import('./modules/selection.js');
      return {
        chipHidden: chip && chip.classList.contains('hidden'),
        selectionActive: isSelectionActive(),
      };
    `, []); // nosemgrep: frozen-baseline-test
    expect(state.chipHidden).toBe(true); // nosemgrep: frozen-baseline-test
    expect(state.selectionActive).toBe(false); // nosemgrep: frozen-baseline-test
  });

  test('Select Visible selects viewport rows and shows Copy button', async ({ driver }, testInfo) => {
    await setupRealSSHConnection(driver);
    await exposeTerminal(driver);

    // Type something so there's visible content
    await sendCommand(driver, 'echo "SELECTION TEST LINE"');
    await driver.pause(1000);
    await dismissKeyboardViaBack(driver);
    await driver.pause(500);

    // Long-press to show chip
    const bounds = await getVisibleTerminalBounds(driver);
    const cx = Math.round((bounds.left + bounds.right) / 2);
    const cy = Math.round((bounds.top + bounds.bottom) / 2);
    await performLongPress(driver, cx, cy);

    // Tap Select Visible
    await driver.executeScript(
      "document.getElementById('selectionVisibleBtn')?.click()", []);
    await driver.pause(500);

    await attachScreenshot(driver, testInfo, 'after-select-visible');

    // Verify: selection exists, copy button visible, chip hidden
    const state = await driver.executeScript(`
      const term = window.__testTerminal;
      const chip = document.getElementById('selectionChip');
      const copyBtn = document.getElementById('handleCopyBtn');
      return {
        hasSelection: !!(term && term.getSelection()),
        selectionLength: term ? term.getSelection().length : 0,
        chipHidden: chip && chip.classList.contains('hidden'),
        copyVisible: copyBtn && !copyBtn.classList.contains('hidden'),
      };
    `, []); // nosemgrep: frozen-baseline-test
    expect(state.hasSelection).toBe(true); // nosemgrep: frozen-baseline-test
    expect(state.selectionLength).toBeGreaterThan(0); // nosemgrep: frozen-baseline-test
    expect(state.chipHidden).toBe(true); // nosemgrep: frozen-baseline-test
    expect(state.copyVisible).toBe(true); // nosemgrep: frozen-baseline-test
  });

  test('Select All selects entire buffer and shows Copy button', async ({ driver }, testInfo) => {
    await setupRealSSHConnection(driver);
    await exposeTerminal(driver);

    await sendCommand(driver, 'echo "SELECT ALL TEST"');
    await driver.pause(1000);
    await dismissKeyboardViaBack(driver);
    await driver.pause(500);

    // Long-press to show chip
    const bounds = await getVisibleTerminalBounds(driver);
    const cx = Math.round((bounds.left + bounds.right) / 2);
    const cy = Math.round((bounds.top + bounds.bottom) / 2);
    await performLongPress(driver, cx, cy);

    // Tap Select All
    await driver.executeScript(
      "document.getElementById('selectionAllBtn')?.click()", []);
    await driver.pause(500);

    await attachScreenshot(driver, testInfo, 'after-select-all');

    const state = await driver.executeScript(`
      const term = window.__testTerminal;
      const copyBtn = document.getElementById('handleCopyBtn');
      return {
        hasSelection: !!(term && term.getSelection()),
        selectionLength: term ? term.getSelection().length : 0,
        copyVisible: copyBtn && !copyBtn.classList.contains('hidden'),
      };
    `, []); // nosemgrep: frozen-baseline-test
    expect(state.hasSelection).toBe(true); // nosemgrep: frozen-baseline-test
    expect(state.selectionLength).toBeGreaterThan(0); // nosemgrep: frozen-baseline-test
    expect(state.copyVisible).toBe(true); // nosemgrep: frozen-baseline-test
  });

  test('scroll gesture works after selection dismiss (no regression)', async ({ driver }, testInfo) => {
    await setupRealSSHConnection(driver);
    await exposeTerminal(driver);

    // Generate some scrollback
    await sendCommand(driver, 'for i in $(seq 1 100); do echo "LINE $i"; done');
    await driver.pause(2000);
    await dismissKeyboardViaBack(driver);
    await driver.pause(500);

    // Long-press → show chip → dismiss
    const bounds = await getVisibleTerminalBounds(driver);
    const cx = Math.round((bounds.left + bounds.right) / 2);
    const cy = Math.round((bounds.top + bounds.bottom) / 2);
    await performLongPress(driver, cx, cy);
    await driver.executeScript(
      "document.getElementById('selectionDismissBtn')?.click()", []);
    await driver.pause(500);

    // Now try scrolling — should work
    await warmupSwipes(driver, bounds);
    const vpBefore = await driver.executeScript(
      'return window.__testTerminal?.buffer.active.viewportY', []);

    await swipeToOlderContent(driver, bounds);
    await driver.pause(1000);

    const vpAfter = await driver.executeScript(
      'return window.__testTerminal?.buffer.active.viewportY', []);

    await attachScreenshot(driver, testInfo, 'after-scroll-post-dismiss');

    // Viewport should have changed (scroll worked)
    expect(vpAfter).not.toBe(vpBefore); // nosemgrep: frozen-baseline-test
  });
});
