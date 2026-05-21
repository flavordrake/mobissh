/**
 * tests/appium/selection-keyboard-stability.spec.js
 *
 * Real-device acceptance for the "keyboard flickers during long-press copy"
 * bug (#502). The headless suite (tests/keyboard-stability-selection.spec.js)
 * passes against current main because headless Chromium has no soft keyboard
 * — focus shifts don't dismiss-and-resummon a virtual IME. This spec runs
 * the same assertions on the Android emulator where the soft keyboard IS
 * real, so visualViewport actually shrinks when the keyboard is up, and
 * focus shifts between textareas trigger the dismiss-and-resummon behavior
 * the user reports.
 *
 * The contract being tested:
 *   Whatever state the soft keyboard is in at touchstart is the state it
 *   stays in for the entire copy gesture (touchstart → 500ms hold →
 *   touchmove → touchend → tap Copy).
 *
 * Three traces are captured during each gesture:
 *   - focus: every focusin/focusout on inputs and .xterm-helper-textarea
 *   - viewport: every visualViewport.resize event
 *   - active: snapshot of document.activeElement at each step
 *
 * MUST run via scripts/run-appium-tests.sh (handles emulator boot, ANR
 * dismissal, screen recording, archival). Never run via bare playwright CLI
 * (per .claude/rules/testing.md).
 */

const {
  test, expect,
  setupRealSSHConnection, setupVault, sendCommand,
  dismissKeyboardViaBack, exposeTerminal,
  getVisibleTerminalBounds, measureScreenOffset,
  switchToNative, switchToWebview,
  dismissNativeDialogs,
  attachScreenshot,
  BASE_URL,
} = require('./fixtures');

const LONG_PRESS_HOLD_MS = 700;     // > 500ms LONG_PRESS_MS threshold + margin
const GESTURE_SETTLE_MS = 250;      // wait for focusIME setTimeout(50) restores
const KEYBOARD_HEIGHT_THRESHOLD = 100; // matches selection.ts inline check

/**
 * Install focus + viewport tracers in the page. Must be called BEFORE the
 * gesture so all events during touchstart..touchend are captured.
 */
async function installTracers(driver) {
  await driver.executeScript(`
    window.__focusTrace = [];
    window.__viewportTrace = [];
    window.__selLog = [];
    window.__installTracersAt = performance.now();
    const origLog = console.log;
    console.log = function(...args) {
      const s = args.map(a => typeof a === 'object' ? JSON.stringify(a) : String(a)).join(' ');
      if (s.indexOf('[sel-suppress]') >= 0) window.__selLog.push(Math.round(performance.now()) + ' ' + s);
      origLog.apply(console, args);
    };
    const stamp = () => Math.round(performance.now());
    const collect = (phase) => (e) => {
      const t = e.target;
      const id = (t && t.id) || '';
      const cls = (t && t.className && typeof t.className === 'string') ? t.className : '';
      window.__focusTrace.push({
        t: stamp(),
        phase,
        id,
        helper: cls.indexOf('xterm-helper-textarea') >= 0,
        tag: (t && t.tagName) || '',
      });
    };
    document.addEventListener('focusin', collect('focusin'), true);
    document.addEventListener('focusout', collect('focusout'), true);
    if (window.visualViewport) {
      window.visualViewport.addEventListener('resize', () => {
        window.__viewportTrace.push({
          t: stamp(),
          height: window.visualViewport.height,
          width: window.visualViewport.width,
          scale: window.visualViewport.scale,
        });
      });
    }
  `, []);
}

/**
 * Drain everything the tracers captured plus the current focus state.
 */
async function drainTraces(driver) {
  return await driver.executeScript(`
    return {
      focus: window.__focusTrace || [],
      viewport: window.__viewportTrace || [],
      selLog: window.__selLog || [],
      installTracersAt: window.__installTracersAt,
      finalActiveId: document.activeElement ? document.activeElement.id : '',
      finalActiveIsHelper:
        !!(document.activeElement &&
           document.activeElement.className &&
           typeof document.activeElement.className === 'string' &&
           document.activeElement.className.indexOf('xterm-helper-textarea') >= 0),
      currentKeyboardHidden: window.visualViewport
        ? (window.visualViewport.height >= window.innerHeight - ${KEYBOARD_HEIGHT_THRESHOLD})
        : true,
      currentVVHeight: window.visualViewport ? window.visualViewport.height : window.innerHeight,
      innerHeight: window.innerHeight,
    };
  `, []);
}

/** Long-press at a screen-pixel coordinate via Appium W3C Actions. */
async function performLongPressAt(driver, screenX, screenY) {
  await switchToNative(driver);
  await driver.performActions([{
    type: 'pointer',
    id: 'sel-finger',
    parameters: { pointerType: 'touch' },
    actions: [
      { type: 'pointerMove', duration: 0, x: Math.round(screenX), y: Math.round(screenY), origin: 'viewport' },
      { type: 'pointerDown', button: 0 },
      { type: 'pause', duration: LONG_PRESS_HOLD_MS },
      { type: 'pointerUp', button: 0 },
    ],
  }]);
  await driver.releaseActions();
  await switchToWebview(driver);
  await driver.pause(GESTURE_SETTLE_MS);
}

/** Long-press + drag horizontally to extend selection, then release. */
async function performLongPressDrag(driver, startX, startY, dragDx = 200) {
  await switchToNative(driver);
  await driver.performActions([{
    type: 'pointer',
    id: 'sel-drag-finger',
    parameters: { pointerType: 'touch' },
    actions: [
      { type: 'pointerMove', duration: 0, x: Math.round(startX), y: Math.round(startY), origin: 'viewport' },
      { type: 'pointerDown', button: 0 },
      { type: 'pause', duration: LONG_PRESS_HOLD_MS },
      { type: 'pointerMove', duration: 200, x: Math.round(startX + dragDx), y: Math.round(startY), origin: 'viewport' },
      { type: 'pause', duration: 100 },
      { type: 'pointerUp', button: 0 },
    ],
  }]);
  await driver.releaseActions();
  await switchToWebview(driver);
  await driver.pause(GESTURE_SETTLE_MS);
}

/** Get terminal center in SCREEN pixels (Appium expects screen, not CSS).
 *  getVisibleTerminalBounds already returns screen-pixel coordinates
 *  (multiplied by dpr inside the fixture); we just take the midpoint. */
async function getTerminalCenterScreenPx(driver) {
  const bounds = await getVisibleTerminalBounds(driver);
  expect(bounds, 'terminal must be on screen').toBeTruthy();
  return {
    x: Math.round((bounds.left + bounds.right) / 2),
    y: Math.round((bounds.top + bounds.bottom) / 2),
  };
}

/** Try to summon the soft keyboard. Returns true if vv.height shrank to
 *  indicate the IME is now visible; false otherwise. JS-initiated focus
 *  is not a user gesture and Chrome 146+ on Android often suppresses the
 *  IME for non-gesture focus calls — this is a best-effort attempt. */
async function trySummonKeyboard(driver) {
  await driver.executeScript(`
    const ime = document.getElementById('imeInput');
    const direct = document.getElementById('directInput');
    const target = (direct && !direct.classList.contains('hidden')) ? direct : ime;
    if (target) {
      target.focus();
      target.click();
    }
  `, []);
  await driver.pause(1500);
  return await driver.executeScript(`
    const vv = window.visualViewport;
    if (!vv) return false;
    return vv.height < window.innerHeight - ${KEYBOARD_HEIGHT_THRESHOLD};
  `, []);
}

/** Confirm the soft keyboard is currently up (or dismissed) per visualViewport. */
async function getKeyboardState(driver) {
  return await driver.executeScript(`
    const vv = window.visualViewport;
    if (!vv) return { knownVisible: false, height: window.innerHeight, innerHeight: window.innerHeight };
    return {
      knownVisible: vv.height < window.innerHeight - ${KEYBOARD_HEIGHT_THRESHOLD},
      height: vv.height,
      innerHeight: window.innerHeight,
    };
  `, []);
}

test.describe('Selection keyboard stability — real Android (#502)', () => {
  test.setTimeout(240_000);

  test.beforeEach(async ({ driver }) => {
    await driver.url(BASE_URL);
    await driver.pause(2000);
    await dismissNativeDialogs(driver);
    await switchToWebview(driver);
    await setupVault(driver);
    await setupRealSSHConnection(driver);
    await exposeTerminal(driver);

    // Seed selectable content so long-press has something to grab. Mix of
    // word, URL, and path covers the three selection modes in selection.ts
    // (_wordAt / _urlAt / _pathAt).
    await sendCommand(driver, 'echo "ALPHA BRAVO CHARLIE https://example.com/path /etc/hosts"');
    await driver.pause(800);
  });

  test('A1: keyboard-visible at touchstart → visualViewport.height does not change during gesture', async ({ driver }, testInfo) => {
    const kbUp = await trySummonKeyboard(driver);
    test.skip(!kbUp, 'JS focus() did not summon the soft keyboard on this emulator (user-gesture requirement). Run via real device or a manual-tap step to exercise A-series.');

    const kbBefore = await getKeyboardState(driver);
    expect(kbBefore.knownVisible).toBe(true);

    await installTracers(driver);

    const { x, y } = await getTerminalCenterScreenPx(driver);
    await performLongPressDrag(driver, x, y);

    await attachScreenshot(driver, testInfo, 'A1-after-gesture');

    const trace = await drainTraces(driver);

    // Primary assertion: visualViewport.height never changed during gesture
    // — the on-device proxy for "soft keyboard never dismissed-and-resummoned"
    expect(
      trace.viewport,
      `visualViewport.resize events fired during gesture (means keyboard moved): ${JSON.stringify(trace.viewport)}`
    ).toHaveLength(0);

    // Keyboard should STILL be visible at the end (vv.height still small)
    expect(
      trace.currentKeyboardHidden,
      `keyboard should still be visible post-gesture (vv.height=${trace.currentVVHeight}, innerHeight=${trace.innerHeight})`
    ).toBe(false);
  });

  test('A2: keyboard-visible at touchstart → activeElement does not flicker through helper-textarea', async ({ driver }, testInfo) => {
    const kbUp = await trySummonKeyboard(driver);
    test.skip(!kbUp, 'JS focus() did not summon the soft keyboard on this emulator (user-gesture requirement). Run via real device or a manual-tap step to exercise A-series.');

    const kbBefore = await getKeyboardState(driver);
    expect(kbBefore.knownVisible).toBe(true);

    await installTracers(driver);

    const { x, y } = await getTerminalCenterScreenPx(driver);
    await performLongPressDrag(driver, x, y);

    await attachScreenshot(driver, testInfo, 'A2-after-gesture');

    const trace = await drainTraces(driver);

    const helperFocusIns = trace.focus.filter((e) => e.phase === 'focusin' && e.helper);
    expect(
      helperFocusIns,
      `.xterm-helper-textarea must not gain focus mid-gesture (it's what triggers the Android Chrome keyboard flicker). trace: ${JSON.stringify(trace.focus)}`
    ).toHaveLength(0);

    // The IME / direct input that had focus pre-gesture should still be
    // the activeElement. Accept either (Direct mode vs Compose mode both
    // satisfy "user-facing input retains focus").
    const finalIsInput = ['imeInput', 'directInput'].includes(trace.finalActiveId);
    expect(
      finalIsInput,
      `activeElement post-gesture should be a user input (got id="${trace.finalActiveId}", isHelper=${trace.finalActiveIsHelper}, trace=${JSON.stringify(trace.focus)})`
    ).toBe(true);
    expect(trace.finalActiveIsHelper).toBe(false);
  });

  test('B1: keyboard-dismissed at touchstart → gesture does not summon keyboard', async ({ driver }, testInfo) => {
    await dismissKeyboardViaBack(driver);
    await driver.pause(800);

    const kbBefore = await getKeyboardState(driver);
    expect(
      kbBefore.knownVisible,
      `keyboard must be dismissed at start (vv.height=${kbBefore.height}, innerHeight=${kbBefore.innerHeight})`
    ).toBe(false);

    await installTracers(driver);

    const { x, y } = await getTerminalCenterScreenPx(driver);
    await performLongPressDrag(driver, x, y);

    await attachScreenshot(driver, testInfo, 'B1-after-gesture');

    const trace = await drainTraces(driver);

    // Always dump the FULL trace before any assertion so the next iteration
    // sees both focus and viewport events even when the viewport assertion
    // fires first. Use console.log + testInfo.attach so it lands in both
    // the run log and the Playwright HTML report.
    const fullTrace = JSON.stringify({
      focus: trace.focus,
      viewport: trace.viewport,
      selLog: trace.selLog,
      finalActiveId: trace.finalActiveId,
      finalActiveIsHelper: trace.finalActiveIsHelper,
      currentVVHeight: trace.currentVVHeight,
      innerHeight: trace.innerHeight,
    }, null, 2);
    // eslint-disable-next-line no-console
    console.log('[B1 FULL TRACE]\n' + fullTrace);
    await testInfo.attach('B1-trace', { body: fullTrace, contentType: 'application/json' });

    const focusIns = trace.focus.filter((e) => e.phase === 'focusin');

    // Check focus FIRST so the next iteration knows which element to silence.
    expect(
      focusIns,
      `no element should gain focus when keyboard was dismissed pre-gesture. focusins: ${JSON.stringify(focusIns)}`
    ).toHaveLength(0);

    // Then viewport (the user-visible symptom).
    expect(
      trace.viewport,
      `visualViewport.resize events during gesture: ${JSON.stringify(trace.viewport)}`
    ).toHaveLength(0);

    // Final state must match starting state.
    expect(
      trace.currentKeyboardHidden,
      `keyboard should still be dismissed post-gesture (vv.height=${trace.currentVVHeight}, innerHeight=${trace.innerHeight})`
    ).toBe(true);
  });

  test('C1: pure long-press without drag — keyboard state stable', async ({ driver }, testInfo) => {
    // Same as A1 but no drag — isolates whether the long-press alone (not
    // the drag-extend) is what flickers the keyboard.
    const kbUp = await trySummonKeyboard(driver);
    test.skip(!kbUp, 'JS focus() did not summon the soft keyboard on this emulator (user-gesture requirement). Run via real device or a manual-tap step to exercise A-series.');

    const kbBefore = await getKeyboardState(driver);
    expect(kbBefore.knownVisible).toBe(true);

    await installTracers(driver);

    const { x, y } = await getTerminalCenterScreenPx(driver);
    await performLongPressAt(driver, x, y);

    await attachScreenshot(driver, testInfo, 'C1-after-long-press-only');

    const trace = await drainTraces(driver);

    expect(
      trace.viewport,
      `viewport resize during pure long-press: ${JSON.stringify(trace.viewport)}`
    ).toHaveLength(0);

    const helperFocusIns = trace.focus.filter((e) => e.phase === 'focusin' && e.helper);
    expect(helperFocusIns).toHaveLength(0);
  });
});
