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
  swipe, pinch,
} = require('./fixtures');

test.describe('Touch gestures (Android emulator + real SSH)', () => {

  test('vertical swipe scrolls terminal scrollback', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await setupRealSSHConnection(page, sshServer);
    await screenshot(page, testInfo, '01-connected');

    // Expose terminal for buffer inspection
    await page.evaluate(async () => {
      const { appState } = await import('./modules/state.js');
      window.__testTerminal = appState.terminal;
    });

    // Generate scrollback: 200 lines of output
    await sendCommand(page, 'seq 1 200');
    await page.waitForTimeout(3000);
    await screenshot(page, testInfo, '02-scrollback-generated');

    // Verify scrollback exists
    const baseY = await page.evaluate(() => window.__testTerminal.buffer.active.baseY);
    expect(baseY).toBeGreaterThan(0);

    // Terminal should be at the bottom (viewportY == baseY)
    const vpBefore = await page.evaluate(() => window.__testTerminal.buffer.active.viewportY);

    // Swipe DOWN (finger moves from top to bottom = scroll UP to see earlier content)
    // ime.ts: totalDy = startY - currentY; when finger goes down, totalDy < 0
    // scrollLines(negative delta) scrolls toward beginning of buffer
    await swipe(page, '#terminal', 200, 100, 200, 500, 20);
    await page.waitForTimeout(500);
    await screenshot(page, testInfo, '03-after-scroll');

    const vpAfter = await page.evaluate(() => window.__testTerminal.buffer.active.viewportY);

    // viewportY should have decreased — we scrolled up to see earlier content
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
    expect(mouseMode).not.toBe('none');

    // Generate enough output for tmux scrollback
    await sendCommand(page, 'seq 1 200');
    await page.waitForTimeout(2000);
    await screenshot(page, testInfo, '10-tmux-output');

    // Clear WS spy to isolate scroll events
    await page.evaluate(() => { window.__mockWsSpy = []; });

    // Swipe DOWN (finger top→bottom) = scroll UP to see older content
    // Should send SGR WheelUp events (button 64): \x1b[<64;col;rowM
    await swipe(page, '#terminal', 200, 100, 200, 500, 20);
    await page.waitForTimeout(500);
    await screenshot(page, testInfo, '11-tmux-after-scroll');

    const msgs = await page.evaluate(() =>
      (window.__mockWsSpy || [])
        .map(s => { try { return JSON.parse(s); } catch { return null; } })
        .filter(m => m && m.type === 'input')
    );

    // Verify SGR mouse wheel events were sent (not scrollLines)
    const sgrEvents = msgs.filter(m => m.data && m.data.startsWith('\x1b[<'));
    expect(sgrEvents.length).toBeGreaterThan(0);

    // Button 64 = WheelUp (scroll to see older content)
    const hasWheelUp = sgrEvents.some(m => m.data.startsWith('\x1b[<64;'));
    const hasWheelDown = sgrEvents.some(m => m.data.startsWith('\x1b[<65;'));
    expect(hasWheelUp).toBe(true);
    // Must NOT contain opposite direction — catches inverted button mapping
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
    await setupRealSSHConnection(page, sshServer);

    // Expose terminal for font size inspection
    await page.evaluate(async () => {
      const { appState } = await import('./modules/state.js');
      window.__testTerminal = appState.terminal;
    });

    const fontBefore = await page.evaluate(() => window.__testTerminal.options.fontSize);
    await screenshot(page, testInfo, '06-before-pinch');

    // Pinch OUT (spread fingers = zoom in = increase font size)
    await pinch(page, '#terminal', 50, 200, 12);
    await page.waitForTimeout(500);

    const fontAfterZoomIn = await page.evaluate(() => window.__testTerminal.options.fontSize);
    await screenshot(page, testInfo, '07-after-pinch-out');
    expect(fontAfterZoomIn).toBeGreaterThan(fontBefore);

    // Pinch IN (fingers together = zoom out = decrease font size)
    await pinch(page, '#terminal', 200, 50, 12);
    await page.waitForTimeout(500);

    const fontAfterZoomOut = await page.evaluate(() => window.__testTerminal.options.fontSize);
    await screenshot(page, testInfo, '08-after-pinch-in');
    expect(fontAfterZoomOut).toBeLessThan(fontAfterZoomIn);
  });
});
