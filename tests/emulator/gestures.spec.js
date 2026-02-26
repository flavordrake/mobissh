/**
 * tests/emulator/gestures.spec.js
 *
 * Touch gesture tests on real Android Chrome via emulator CDP.
 * Tests vertical scroll, horizontal swipe (tmux), and pinch-to-zoom.
 *
 * Requires: Docker test-sshd running (port 2222), Android emulator with CDP.
 * Uses Page.screencastFrame for low-fps motion capture of gesture results.
 */

const {
  test, expect, screenshot, setupRealSSHConnection, sendCommand,
  swipe, pinch, startScreencast, BASE_URL,
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

    // Start screencast to capture the scroll animation
    const cast = startScreencast(page, null);
    await cast.start();

    // Swipe DOWN (finger moves from top to bottom = scroll UP to see earlier content)
    // ime.ts: totalDy = startY - currentY; when finger goes down, totalDy < 0
    // scrollLines(negative delta) scrolls toward beginning of buffer
    await swipe(page, '#terminal', 200, 100, 200, 500, 20);
    await page.waitForTimeout(500);

    const frameCount = await cast.stop(testInfo, 'scroll-animation');
    await screenshot(page, testInfo, '03-after-scroll');

    const vpAfter = await page.evaluate(() => window.__testTerminal.buffer.active.viewportY);

    // viewportY should have decreased — we scrolled up to see earlier content
    expect(vpAfter).toBeLessThan(vpBefore);
  });

  test('horizontal swipe sends tmux prefix commands', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await setupRealSSHConnection(page, sshServer);

    // Clear WS spy to isolate swipe messages
    await page.evaluate(() => { window.__mockWsSpy = []; });

    const cast = startScreencast(page, null);
    await cast.start();

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

    await cast.stop(testInfo, 'swipe-animation');
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

    const cast = startScreencast(page, null);
    await cast.start();

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

    await cast.stop(testInfo, 'pinch-animation');
  });
});
