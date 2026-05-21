/**
 * tests/keyboard-stability-selection.spec.js
 *
 * Headless acceptance suite for the recurring "keyboard flickers during
 * long-press copy" bug (#502).
 *
 * THE CONTRACT (what users actually experience):
 *   Whatever state the soft keyboard is in when a long-press starts is the
 *   state it stays in for the entire copy gesture sequence:
 *     touchstart → 500ms hold → touchmove → touchend → click(Copy button)
 *
 * THE HEADLESS PROXY:
 *   In a headless browser there is no real soft keyboard, and visualViewport
 *   height does not change on focus. We test the *proximate JS cause* of the
 *   on-device keyboard flicker instead:
 *
 *     1. `.xterm-helper-textarea` (an internal xterm.js element) must NEVER
 *        become document.activeElement during the gesture. xterm's
 *        `term.select()` synchronously focuses it; on a real device, that
 *        focus shift causes Android Chrome to drop and re-summon the soft
 *        keyboard, which fires a visualViewport.resize during the drag and
 *        de-anchors the user's selection.
 *
 *     2. If `#imeInput` was focused at touchstart, it must stay
 *        document.activeElement after touchend AND after the Copy click.
 *        No element other than #imeInput may receive a focusin during the
 *        gesture sequence.
 *
 *     3. If no element was focused at touchstart, no element may gain focus
 *        during the gesture (the "keyboard dismissed" case must stay
 *        dismissed).
 *
 *   These three rules together make the on-device keyboard flicker
 *   impossible regardless of how Android Chrome reacts to focus events.
 *
 * THIS SPEC IS WRITTEN TO FAIL until #502 is fixed. The failing assertions
 * are intentional and serve as the regression catch for the next time the
 * selection / focus interaction drifts.
 */

const { test, expect, setupConnected } = require('./fixtures.js');

const TERMINAL_CELL_SELECTOR = '.xterm-screen';
const IME_INPUT = '#imeInput';
const HELPER_SELECTOR = '.xterm-helper-textarea';
const COPY_BTN = '#handleCopyBtn';

/**
 * Override window.visualViewport.height so `_onLongPress`'s inline check
 *   const kbVisibleNow = !!vv && vv.height < window.innerHeight - 100;
 * returns true. This is how the app detects "soft keyboard visible" on
 * a real device — without overriding, headless reports vv.height ===
 * window.innerHeight and the inline check returns false, exercising a
 * different code path than the user's reported bug.
 *
 * Returns a teardown function that restores the original viewport.
 */
async function simulateKeyboardVisible(page) {
  await page.evaluate(() => {
    if (!window.visualViewport) return;
    const fakeHeight = window.innerHeight - 300; // ~Android Chrome IME
    window.__originalVVDescriptor = Object.getOwnPropertyDescriptor(
      Object.getPrototypeOf(window.visualViewport), 'height'
    );
    Object.defineProperty(window.visualViewport, 'height', {
      configurable: true,
      get() { return fakeHeight; },
    });
    // visualViewport.resize doesn't fire automatically when we override,
    // but our code reads .height inline — that's enough.
  });
}

/**
 * Install focus-trace + visualViewport-trace probes BEFORE any gesture
 * fires. Returns a function that drains the traces back out.
 */
async function installFocusTraps(page) {
  await page.evaluate(() => {
    window.__focusTrace = [];
    window.__viewportTrace = [];
    const stamp = () => Math.round(performance.now());
    const focusinHandler = (e) => {
      const t = e.target;
      const id = (t && t.id) || '';
      const cls = (t && t.className && typeof t.className === 'string') ? t.className : '';
      window.__focusTrace.push({
        t: stamp(),
        phase: 'focusin',
        id,
        helper: cls.includes('xterm-helper-textarea'),
      });
    };
    const focusoutHandler = (e) => {
      const t = e.target;
      const id = (t && t.id) || '';
      const cls = (t && t.className && typeof t.className === 'string') ? t.className : '';
      window.__focusTrace.push({
        t: stamp(),
        phase: 'focusout',
        id,
        helper: cls.includes('xterm-helper-textarea'),
      });
    };
    document.addEventListener('focusin', focusinHandler, true);
    document.addEventListener('focusout', focusoutHandler, true);

    if (window.visualViewport) {
      window.visualViewport.addEventListener('resize', () => {
        window.__viewportTrace.push({
          t: stamp(),
          height: window.visualViewport.height,
          scale: window.visualViewport.scale,
        });
      });
    }
  });
}

async function drainTraces(page) {
  return await page.evaluate(() => ({
    focus: window.__focusTrace || [],
    viewport: window.__viewportTrace || [],
    finalActiveId: document.activeElement ? document.activeElement.id : '',
    finalActiveIsHelper:
      !!(document.activeElement &&
         document.activeElement.className &&
         typeof document.activeElement.className === 'string' &&
         document.activeElement.className.includes('xterm-helper-textarea')),
  }));
}

/**
 * Drive the full long-press → drag → release sequence on the terminal at
 * the given client coordinates. Returns nothing; trace remains in
 * window.__focusTrace.
 */
async function longPressDragRelease(page, { startX, startY, dragDx = 80, dragDy = 0, holdMs = 600 }) {
  const term = page.locator(TERMINAL_CELL_SELECTOR);

  // 1. touchstart
  await term.evaluate(
    (el, args) => {
      const touch = new Touch({ identifier: 1, target: el, clientX: args.x, clientY: args.y });
      el.dispatchEvent(new TouchEvent('touchstart', { touches: [touch], changedTouches: [touch], bubbles: true, cancelable: true }));
    },
    { x: startX, y: startY }
  );

  // 2. hold over long-press threshold (500ms)
  await page.waitForTimeout(holdMs);

  // 3. touchmove to extend
  await term.evaluate(
    (el, args) => {
      const touch = new Touch({ identifier: 1, target: el, clientX: args.x + args.dx, clientY: args.y + args.dy });
      el.dispatchEvent(new TouchEvent('touchmove', { touches: [touch], changedTouches: [touch], bubbles: true, cancelable: true }));
    },
    { x: startX, y: startY, dx: dragDx, dy: dragDy }
  );

  // 4. touchend
  await term.evaluate(
    (el, args) => {
      const touch = new Touch({ identifier: 1, target: el, clientX: args.x + args.dx, clientY: args.y + args.dy });
      el.dispatchEvent(new TouchEvent('touchend', { touches: [], changedTouches: [touch], bubbles: true, cancelable: true }));
    },
    { x: startX, y: startY, dx: dragDx, dy: dragDy }
  );

  // Small settling delay — xterm.js's helper focus + our gated blur are
  // synchronous, but the focusin/focusout events may queue across a
  // microtask.
  await page.waitForTimeout(20);
}

async function getTerminalCenter(page) {
  return await page.locator(TERMINAL_CELL_SELECTOR).evaluate((el) => {
    const r = el.getBoundingClientRect();
    return { x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2) };
  });
}

test.describe('Keyboard stability across selection gesture (#502)', () => {
  // WebKit and Firefox both lack the Touch() constructor in headless mode.
  // Selection gesture handling is Android Chrome-shaped anyway.
  test.skip(({ browserName }) => browserName !== 'chromium', 'Touch() requires Chromium');

  test.beforeEach(async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await installFocusTraps(page);
  });

  test('A1: long-press never lets .xterm-helper-textarea become activeElement', async ({ page }) => {
    // Pre-state: keyboard "visible" + focus on imeInput — exactly the
    // scenario the user reported as flickering.
    await simulateKeyboardVisible(page);
    await page.evaluate((sel) => { document.querySelector(sel)?.focus(); }, IME_INPUT);
    const beforeId = await page.evaluate(() => document.activeElement?.id || '');
    expect(beforeId).toBe('imeInput');

    const { x, y } = await getTerminalCenter(page);
    await longPressDragRelease(page, { startX: x, startY: y });

    const trace = await drainTraces(page);

    // The proximate JS cause of the on-device keyboard flicker:
    // helper textarea taking focus, even briefly, during the gesture.
    const helperFocusInEvents = trace.focus.filter((e) => e.phase === 'focusin' && e.helper);
    expect(
      helperFocusInEvents,
      `xterm-helper-textarea must not gain focus during long-press selection — it's what triggers the soft-keyboard flicker on Android Chrome. trace: ${JSON.stringify(trace.focus)}`
    ).toHaveLength(0);
  });

  test('A2: when #imeInput had focus pre-gesture, it still has focus post-gesture', async ({ page }) => {
    await simulateKeyboardVisible(page);
    await page.evaluate((sel) => { document.querySelector(sel)?.focus(); }, IME_INPUT);

    const { x, y } = await getTerminalCenter(page);
    await longPressDragRelease(page, { startX: x, startY: y });

    // Allow up to 100ms for the _dismissSelection focusIME restore to settle.
    // (selection.ts uses setTimeout(focusIME, 50) on its restore paths.)
    await page.waitForTimeout(150);

    const trace = await drainTraces(page);

    expect(
      trace.finalActiveId,
      `activeElement after gesture should still be #imeInput (focus trace: ${JSON.stringify(trace.focus)})`
    ).toBe('imeInput');
    expect(trace.finalActiveIsHelper).toBe(false);
  });

  test('A3: copy button click does not steal focus to the helper', async ({ page }) => {
    await simulateKeyboardVisible(page);
    await page.evaluate((sel) => { document.querySelector(sel)?.focus(); }, IME_INPUT);

    const { x, y } = await getTerminalCenter(page);
    await longPressDragRelease(page, { startX: x, startY: y });

    // Copy button only shows when selection is active. If selection didn't
    // produce non-empty text (mock terminal may render blank), tolerate
    // the button being hidden — focus assertion still applies generically.
    const copyVisible = await page.locator(COPY_BTN).isVisible().catch(() => false);
    if (copyVisible) {
      await page.locator(COPY_BTN).click();
      await page.waitForTimeout(20);
    }

    const trace = await drainTraces(page);
    const helperFocusInEvents = trace.focus.filter((e) => e.phase === 'focusin' && e.helper);
    expect(helperFocusInEvents).toHaveLength(0);
  });

  test('B1: when nothing was focused pre-gesture, nothing is focused post-gesture', async ({ page }) => {
    // Pre-state: blur whatever has focus (simulates "keyboard dismissed")
    await page.evaluate(() => {
      const el = document.activeElement;
      if (el && el instanceof HTMLElement) el.blur();
    });
    const beforeId = await page.evaluate(() => document.activeElement?.id || '');
    // body or empty is acceptable; what matters is no input element has focus
    expect(['', 'body']).toContain(beforeId);

    const { x, y } = await getTerminalCenter(page);
    await longPressDragRelease(page, { startX: x, startY: y });

    const trace = await drainTraces(page);

    expect(
      trace.finalActiveIsHelper,
      `helper textarea must not be activeElement after gesture (focus trace: ${JSON.stringify(trace.focus)})`
    ).toBe(false);

    // No focusin on imeInput either — we shouldn't summon a keyboard the
    // user had dismissed.
    const imeFocusInEvents = trace.focus.filter((e) => e.phase === 'focusin' && e.id === 'imeInput');
    expect(
      imeFocusInEvents,
      'When the keyboard was dismissed pre-gesture, the gesture must not re-focus #imeInput'
    ).toHaveLength(0);
  });

  test('B2: long-press from blurred state never focuses helper textarea', async ({ page }) => {
    await page.evaluate(() => {
      const el = document.activeElement;
      if (el && el instanceof HTMLElement) el.blur();
    });

    const { x, y } = await getTerminalCenter(page);
    await longPressDragRelease(page, { startX: x, startY: y });

    const trace = await drainTraces(page);
    const helperFocusInEvents = trace.focus.filter((e) => e.phase === 'focusin' && e.helper);
    expect(helperFocusInEvents).toHaveLength(0);
  });

  test('A4: with kb-visible, #imeInput never receives a focusout during the gesture', async ({ page }) => {
    // Stronger than A2: not only must imeInput be focused at the end, it
    // must never lose focus AT ANY POINT during the gesture. Any focusout
    // — even one that's immediately followed by a focusin restore — would
    // cause a flicker on a real device because the soft keyboard reads
    // focus changes synchronously.
    await simulateKeyboardVisible(page);
    await page.evaluate((sel) => { document.querySelector(sel)?.focus(); }, IME_INPUT);

    const { x, y } = await getTerminalCenter(page);
    await longPressDragRelease(page, { startX: x, startY: y });
    await page.waitForTimeout(150);

    const trace = await drainTraces(page);
    const imeFocusOuts = trace.focus.filter((e) => e.phase === 'focusout' && e.id === 'imeInput');
    expect(
      imeFocusOuts,
      `#imeInput must not lose focus during the gesture. trace: ${JSON.stringify(trace.focus)}`
    ).toHaveLength(0);
  });

  test('A5: visualViewport.resize must not fire during the gesture (proxies on-device keyboard flicker)', async ({ page }) => {
    // On real Android Chrome, ANY focus transition between two textareas
    // can dismiss-and-re-summon the soft keyboard, which fires
    // visualViewport.resize. Our selection.ts has a viewport-aware reflow
    // chain (terminal.ts re-fits on visualViewport resize → buffer
    // coordinates shift → drag-select de-anchors). If we see resize events
    // during the gesture, the on-device flicker is structurally possible
    // even if focus tracing looks clean.
    await simulateKeyboardVisible(page);
    await page.evaluate((sel) => { document.querySelector(sel)?.focus(); }, IME_INPUT);

    const { x, y } = await getTerminalCenter(page);
    await longPressDragRelease(page, { startX: x, startY: y });

    const trace = await drainTraces(page);
    expect(
      trace.viewport,
      `visualViewport must not resize during gesture. events: ${JSON.stringify(trace.viewport)}`
    ).toHaveLength(0);
  });

  test('D1: gesture-log captures focusin events during the gesture (#502 telemetry)', async ({ page }) => {
    // Confirms the production diagnostic instrumentation actually fires
    // during a real headless gesture — not just in mocked unit tests.
    // The gesture-log ring buffer is in localStorage under
    // 'mobissh.gestureLog.v1'. A long-press triggers term.select() which
    // synchronously focuses the helper textarea. The gesture-window listener
    // installed by selection.ts should log that focusin.
    await simulateKeyboardVisible(page);
    await page.evaluate((sel) => { document.querySelector(sel)?.focus(); }, IME_INPUT);

    // Snapshot existing gesture log so we only inspect events from THIS gesture.
    const baselineLen = await page.evaluate(() => {
      try {
        const raw = localStorage.getItem('mobissh.gestureLog.v1');
        if (!raw) return 0;
        const arr = JSON.parse(raw);
        return Array.isArray(arr) ? arr.length : 0;
      } catch { return 0; }
    });

    const { x, y } = await getTerminalCenter(page);
    await longPressDragRelease(page, { startX: x, startY: y });
    // Wait past the 2s gesture-window tail so window close logging runs.
    await page.waitForTimeout(2200);

    const events = await page.evaluate((startIdx) => {
      try {
        const raw = localStorage.getItem('mobissh.gestureLog.v1');
        if (!raw) return [];
        const arr = JSON.parse(raw);
        if (!Array.isArray(arr)) return [];
        return arr.slice(startIdx);
      } catch { return []; }
    }, baselineLen);

    // The new event types must appear after a real gesture. The "audit"
    // snapshot is always logged on touchstart, so it's the most reliable
    // proof the gesture window opened.
    const auditCount = events.filter((e) => e.e === 'gesture_helper_focus_audit').length;
    expect(
      auditCount,
      `gesture_helper_focus_audit must be logged on touchstart. recent events: ${JSON.stringify(events.map((e) => e.e))}`,
    ).toBeGreaterThan(0);

    // If the headless gesture caused any focusin (it normally does because
    // xterm.js's term.select() focuses the helper), it must have been
    // captured by the gesture-window listener.
    const focusinEvents = events.filter((e) => e.e === 'gesture_focusin');
    // We don't assert > 0 unconditionally — a degenerate selection (empty
    // line) skips term.select() — but if the page had ANY focusin event
    // visible to installFocusTraps, the gesture log must mirror it.
    const trace = await drainTraces(page);
    if (trace.focus.some((f) => f.phase === 'focusin')) {
      expect(
        focusinEvents.length,
        `gesture-window listener should have captured focusin events: ${JSON.stringify(events.map((e) => e.e))}`,
      ).toBeGreaterThan(0);
    }
  });

  test('C1: visualViewport height is stable across the gesture (headless trivial pass — documents intent)', async ({ page }) => {
    await page.evaluate((sel) => { document.querySelector(sel)?.focus(); }, IME_INPUT);

    const heightBefore = await page.evaluate(() => window.visualViewport?.height || window.innerHeight);

    const { x, y } = await getTerminalCenter(page);
    await longPressDragRelease(page, { startX: x, startY: y });

    const heightAfter = await page.evaluate(() => window.visualViewport?.height || window.innerHeight);
    const trace = await drainTraces(page);

    // In headless this is trivially true (no soft keyboard). On a real
    // device, focus-shift to .xterm-helper-textarea fires visualViewport
    // resize as the keyboard dismisses-and-redraws. The headless proxy is
    // the A-series helper-focus assertion. We keep this assertion here so
    // Appium/emulator runs of the same suite catch the real-device case.
    expect(heightAfter).toBe(heightBefore);
    expect(trace.viewport).toHaveLength(0);
  });
});
