/**
 * tests/emulator/gestures.spec.js
 *
 * Touch gesture tests on real Android Chrome via emulator CDP.
 * Tests vertical scroll, horizontal swipe (tmux), and pinch-to-zoom.
 *
 * Requires: Docker test-sshd running (port 2222), Android emulator with CDP.
 * Screen recording is handled by run-emulator-tests.sh (adb screenrecord).
 */

const {
  test, expect, screenshot, setupRealSSHConnection, sendCommand,
  swipe, pinch, adbSwipe, dismissKeyboard, ensureKeyboardDismissed,
  warmupTouch, getVisibleTerminalBounds,
  swipeToOlderContent, swipeToNewerContent, expectedSGRButton,
} = require('./fixtures');

test.describe('Touch gestures (Android emulator + real SSH)', () => {

  test('vertical swipe scrolls terminal scrollback', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await setupRealSSHConnection(page, sshServer);

    // Expose terminal for buffer inspection
    await page.evaluate(async () => {
      const { appState } = await import('./modules/state.js');
      window.__testTerminal = appState.terminal;
    });

    // Generate scrollback: 200 lines of output
    await sendCommand(page, 'seq 1 200');
    await page.waitForTimeout(3000);

    // Verify scrollback exists
    const baseY = await page.evaluate(() => window.__testTerminal.buffer.active.baseY);
    expect(baseY).toBeGreaterThan(0);

    const vpBefore = await page.evaluate(() => window.__testTerminal.buffer.active.viewportY);

    // Dismiss keyboard, get bounds, prime touch pipeline
    await ensureKeyboardDismissed(page);
    const bounds = await getVisibleTerminalBounds(page);
    expect(bounds).not.toBeNull();
    warmupTouch(bounds);
    await page.waitForTimeout(500);

    // Intent: scroll to older content
    await swipeToOlderContent(page, bounds);
    await page.waitForTimeout(2000);

    const vpAfter = await page.evaluate(() => window.__testTerminal.buffer.active.viewportY);
    expect(vpAfter).toBeLessThan(vpBefore);
  });

  test('horizontal swipe sends tmux prefix commands', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await setupRealSSHConnection(page, sshServer);

    // Clear WS spy to isolate swipe messages
    await page.evaluate(() => { window.__mockWsSpy = []; });

    // Swipe LEFT: finger moves right-to-left = negative finalDx
    // ime.ts line 461: finalDx < 0 → sends \x02p (tmux previous window)
    await swipe(page, '#terminal', 350, 300, 50, 300, 12);
    await page.waitForTimeout(500);

    let msgs = await page.evaluate(() =>
      (window.__mockWsSpy || [])
        .map(s => { try { return JSON.parse(s); } catch { return null; } })
        .filter(m => m && m.type === 'input')
    );
    await screenshot(page, testInfo, '04-after-left-swipe');
    expect(msgs.some(m => m.data === '\x02p')).toBe(true);

    // Clear and swipe RIGHT: finger moves left-to-right = positive finalDx
    // ime.ts: finalDx > 0 → sends \x02n (tmux next window)
    await page.evaluate(() => { window.__mockWsSpy = []; });
    await swipe(page, '#terminal', 50, 300, 350, 300, 12);
    await page.waitForTimeout(500);

    msgs = await page.evaluate(() =>
      (window.__mockWsSpy || [])
        .map(s => { try { return JSON.parse(s); } catch { return null; } })
        .filter(m => m && m.type === 'input')
    );
    await screenshot(page, testInfo, '05-after-right-swipe');
    expect(msgs.some(m => m.data === '\x02n')).toBe(true);
  });

  test('tmux vertical scroll sends SGR mouse wheel events', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await setupRealSSHConnection(page, sshServer);

    // Capture console logs from scroll handler
    const scrollLogs = [];
    page.on('console', msg => {
      const text = msg.text();
      if (text.includes('[scroll]')) scrollLogs.push(text);
    });

    // Start tmux — mouse mode is on via .tmux.conf
    await sendCommand(page, 'tmux new-session -d -s test');
    await page.waitForTimeout(500);
    await sendCommand(page, 'tmux attach -t test');
    await page.waitForTimeout(1500);
    await screenshot(page, testInfo, '09-tmux-attached');

    // Verify mouse tracking mode is active (tmux enables DECSET 1002+1006)
    const mouseMode = await page.evaluate(async () => {
      const { appState } = await import('./modules/state.js');
      window.__testTerminal = appState.terminal;
      return appState.terminal.modes?.mouseTrackingMode;
    });

    // Generate enough output for tmux scrollback
    await sendCommand(page, 'seq 1 200');
    await page.waitForTimeout(2000);
    await screenshot(page, testInfo, '10-tmux-output');

    // Dismiss keyboard and get terminal bounds
    await ensureKeyboardDismissed(page);

    // Check state after keyboard dismiss
    const postDismiss = await page.evaluate(() => {
      const vv = window.visualViewport;
      return {
        vvHeight: vv?.height, innerHeight: window.innerHeight,
        activeEl: document.activeElement?.tagName + '#' + document.activeElement?.id,
      };
    });

    const bounds = await getVisibleTerminalBounds(page);
    expect(bounds).not.toBeNull();

    const mouseModeAtSwipe = await page.evaluate(async () => {
      const { appState } = await import('./modules/state.js');
      const t = appState.terminal;
      return { mouseMode: t?.modes?.mouseTrackingMode, connected: appState.sshConnected, wsReady: appState.ws?.readyState };
    });

    // Inject touch event tracer BEFORE warmup to capture everything
    await page.evaluate(() => {
      window.__touchTrace = { warmup: [], assertion: [], phase: 'warmup' };
      const el = document.getElementById('terminal');
      // Also listen on document to catch events that miss #terminal
      const logTo = (arr) => (e) => {
        const t = e.touches[0] || e.changedTouches[0];
        arr.push({ type: e.type, y: t?.clientY, target: e.target?.className?.substring(0, 30), ts: Date.now() });
      };
      el.addEventListener('touchstart', logTo(window.__touchTrace.warmup), { capture: true });
      el.addEventListener('touchmove', logTo(window.__touchTrace.warmup), { capture: true });
      el.addEventListener('touchend', logTo(window.__touchTrace.warmup), { capture: true });
      document.addEventListener('touchstart', (e) => {
        const t = e.touches[0] || e.changedTouches[0];
        const phase = window.__touchTrace.phase;
        window.__touchTrace[phase].push({ type: 'doc-' + e.type, y: t?.clientY, target: e.target?.className?.substring(0, 30), ts: Date.now() });
      });
      document.addEventListener('touchmove', (e) => {
        const t = e.touches[0] || e.changedTouches[0];
        const phase = window.__touchTrace.phase;
        window.__touchTrace[phase].push({ type: 'doc-' + e.type, y: t?.clientY, target: e.target?.className?.substring(0, 30), ts: Date.now() });
      });
    });

    // Prime ADB touch pipeline
    warmupTouch(bounds);
    await page.waitForTimeout(500);

    // Check warmup results + state
    const warmupResult = await page.evaluate(() => {
      const vv = window.visualViewport;
      const result = {
        warmupEvents: window.__touchTrace.warmup.length,
        vvHeight: vv?.height, innerHeight: window.innerHeight,
        activeEl: document.activeElement?.tagName + '#' + document.activeElement?.id,
      };
      // Switch to assertion phase and re-wire listeners
      window.__touchTrace.phase = 'assertion';
      window.__touchTrace.warmup = window.__touchTrace.warmup.slice(0, 5); // keep first 5 only
      return result;
    });

    scrollLogs.length = 0;
    await page.evaluate(() => { window.__mockWsSpy = []; });

    // Intent: scroll to older content (3 swipes for enough distance)
    await swipeToOlderContent(page, bounds);
    await page.waitForTimeout(800);
    await swipeToOlderContent(page, bounds);
    await page.waitForTimeout(800);
    await swipeToOlderContent(page, bounds);
    await page.waitForTimeout(1500);
    await screenshot(page, testInfo, '11-tmux-after-scroll');

    const msgs = await page.evaluate(() =>
      (window.__mockWsSpy || [])
        .map(s => { try { return JSON.parse(s); } catch { return null; } })
        .filter(m => m && m.type === 'input')
    );

    // Verify SGR mouse wheel events were sent (not scrollLines)
    const sgrEvents = msgs.filter(m => m.data && m.data.startsWith('\x1b[<'));

    // Collect touch trace (structured: warmup vs assertion)
    const touchTrace = await page.evaluate(() => window.__touchTrace || { warmup: [], assertion: [] });

    // Write diagnostic to /tmp for reliable reading
    const diagContent = [
      `mouseMode at attach: ${mouseMode}`,
      `mouseMode at swipe: ${JSON.stringify(mouseModeAtSwipe)}`,
      `bounds: ${JSON.stringify(bounds)}`,
      `postDismiss: ${JSON.stringify(postDismiss)}`,
      `warmupResult: ${JSON.stringify(warmupResult)}`,
      `total input msgs: ${msgs.length}`,
      `SGR events: ${sgrEvents.length}`,
      '',
      `WARMUP touch events: ${touchTrace.warmup?.length || 0}`,
      `  first 5: ${JSON.stringify((touchTrace.warmup || []).slice(0, 5))}`,
      '',
      `ASSERTION touch events: ${touchTrace.assertion?.length || 0}`,
      `  first 5: ${JSON.stringify((touchTrace.assertion || []).slice(0, 5))}`,
      '',
      `scroll handler logs (${scrollLogs.length}):`,
      ...scrollLogs.slice(0, 20),
    ].join('\n');
    require('fs').writeFileSync('/tmp/sgr-diagnostic.txt', diagContent);
    await testInfo.attach('tmux-sgr-diagnostic', {
      body: Buffer.from(diagContent), contentType: 'text/plain',
    });

    expect(mouseMode, 'tmux mouse mode must be active').not.toBe('none');
    expect(sgrEvents.length).toBeGreaterThan(0);

    // Button 64 = WheelUp (scroll to older) regardless of direction setting
    const { older, newer } = expectedSGRButton();
    const hasWheelUp = sgrEvents.some(m => m.data.startsWith(`\x1b[<${older};`));
    const hasWheelDown = sgrEvents.some(m => m.data.startsWith(`\x1b[<${newer};`));
    expect(hasWheelUp).toBe(true);
    expect(hasWheelDown).toBe(false);

    // Clean up tmux
    await sendCommand(page, 'exit');
    await page.waitForTimeout(500);
  });

  test('tmux horizontal swipe switches windows', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await setupRealSSHConnection(page, sshServer);

    // Start tmux with two windows
    await sendCommand(page, 'tmux new-session -d -s swipe');
    await page.waitForTimeout(500);
    await sendCommand(page, 'tmux attach -t swipe');
    await page.waitForTimeout(1500);

    // Create a second window
    await sendCommand(page, 'tmux new-window');
    await page.waitForTimeout(500);
    await sendCommand(page, 'echo "WINDOW_TWO"');
    await page.waitForTimeout(500);
    await screenshot(page, testInfo, '12-tmux-window2');

    // Clear spy, swipe LEFT (→ tmux previous window)
    await page.evaluate(() => { window.__mockWsSpy = []; });
    await swipe(page, '#terminal', 350, 300, 50, 300, 12);
    await page.waitForTimeout(500);
    await screenshot(page, testInfo, '13-tmux-after-left-swipe');

    let msgs = await page.evaluate(() =>
      (window.__mockWsSpy || [])
        .map(s => { try { return JSON.parse(s); } catch { return null; } })
        .filter(m => m && m.type === 'input')
    );
    expect(msgs.some(m => m.data === '\x02p')).toBe(true);

    // Clear spy, swipe RIGHT (→ tmux next window)
    await page.evaluate(() => { window.__mockWsSpy = []; });
    await swipe(page, '#terminal', 50, 300, 350, 300, 12);
    await page.waitForTimeout(500);
    await screenshot(page, testInfo, '14-tmux-after-right-swipe');

    msgs = await page.evaluate(() =>
      (window.__mockWsSpy || [])
        .map(s => { try { return JSON.parse(s); } catch { return null; } })
        .filter(m => m && m.type === 'input')
    );
    expect(msgs.some(m => m.data === '\x02n')).toBe(true);

    // Clean up
    await sendCommand(page, 'tmux kill-session -t swipe');
    await page.waitForTimeout(500);
  });

  test('pinch-to-zoom changes terminal font size', async ({ emulatorPage: page, sshServer }, testInfo) => {
    // Enable pinch zoom (off by default)
    await page.evaluate(() => localStorage.setItem('enablePinchZoom', 'true'));
    await page.reload({ waitUntil: 'domcontentloaded' });

    // Vault modal may reappear after reload — dismiss if so
    const modalAppeared = await page.locator('#vaultSetupOverlay:not(.hidden)')
      .waitFor({ state: 'visible', timeout: 3000 }).then(() => true).catch(() => false);
    if (modalAppeared) {
      await page.locator('#vaultNewPw').fill('test');
      await page.locator('#vaultConfirmPw').fill('test');
      await page.evaluate(() => {
        const cb = document.getElementById('vaultEnableBio');
        if (cb) cb.checked = false;
      });
      await page.evaluate(() => document.getElementById('vaultSetupCreate')?.click());
      await page.locator('#vaultSetupOverlay').waitFor({ state: 'hidden', timeout: 5000 });
    }
    await page.locator('[data-panel="terminal"]').click();

    await setupRealSSHConnection(page, sshServer);

    await page.evaluate(async () => {
      const { appState } = await import('./modules/state.js');
      window.__testTerminal = appState.terminal;
    });

    const fontBefore = await page.evaluate(() => window.__testTerminal.options.fontSize);
    await screenshot(page, testInfo, '06-before-pinch');

    // Dismiss keyboard so pinch lands on terminal
    dismissKeyboard();
    await page.waitForTimeout(500);

    // Pinch OUT (spread fingers = zoom in = increase font size)
    await pinch(page, '#terminal', 50, 200, 12);

    // Wait for font size to actually change (RAF-based update)
    await page.waitForFunction(
      (before) => (window.__testTerminal?.options.fontSize ?? before) > before,
      fontBefore,
      { timeout: 5000 }
    );
    const fontAfterZoomIn = await page.evaluate(() => window.__testTerminal.options.fontSize);
    await screenshot(page, testInfo, '07-after-pinch-out');
    expect(fontAfterZoomIn).toBeGreaterThan(fontBefore);

    // Pinch IN (fingers together = zoom out = decrease font size)
    await pinch(page, '#terminal', 200, 50, 12);
    await page.waitForFunction(
      (after) => (window.__testTerminal?.options.fontSize ?? after) < after,
      fontAfterZoomIn,
      { timeout: 5000 }
    );
    const fontAfterZoomOut = await page.evaluate(() => window.__testTerminal.options.fontSize);
    await screenshot(page, testInfo, '08-after-pinch-in');
    expect(fontAfterZoomOut).toBeLessThan(fontAfterZoomIn);
  });
});
