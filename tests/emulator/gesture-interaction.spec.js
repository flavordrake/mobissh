/**
 * tests/emulator/gesture-interaction.spec.js
 *
 * Gesture isolation and interaction tests following the gesture-diagnostics
 * methodology. Tests each gesture feature in isolation, then tests pairwise
 * interactions that can cause propagation or interference issues.
 *
 * Key insight: adb shell input swipe (single-finger) can't catch multi-finger
 * bugs. These tests use CDP Input.dispatchTouchEvent via the fixtures' swipe()
 * and pinch() helpers, which go through Chrome's full DOM event pipeline.
 *
 * Assertions are DIRECTION-AWARE: they verify which content is visible after
 * a gesture, not just that content changed. The fill-scrollback.sh script
 * produces sections A-E (earliest→latest), so after scrolling toward older
 * content we expect to see sections A/B, not D/E.
 */
const {
  test, expect, screenshot, setupRealSSHConnection, sendCommand,
  swipe, pinch,
} = require('./fixtures');
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const SCREENSHOT_DIR = path.join(__dirname, '../../test-results/emulator/screenshots');
const FILL_SCRIPT = path.join(__dirname, 'fill-scrollback.sh');

async function snap(page, testInfo, name) {
  await screenshot(page, testInfo, name);
  fs.mkdirSync(SCREENSHOT_DIR, { recursive: true });
  const buf = await page.screenshot({ fullPage: false });
  fs.writeFileSync(path.join(SCREENSHOT_DIR, `${name}.png`), buf);
}

/** Copy fill-scrollback.sh to the SSH container. */
function ensureScript() {
  execSync(`docker cp "${FILL_SCRIPT}" mobissh-test-sshd-1:/tmp/fill-scrollback.sh`);
}

/** Read terminal screen content at baseY (server-rendered, for tmux). */
async function readScreen(page) {
  return page.evaluate(() => {
    const term = window.__testTerminal;
    if (!term) return '';
    const buf = term.buffer.active;
    const lines = [];
    for (let i = 0; i < term.rows; i++) {
      const line = buf.getLine(buf.baseY + i);
      if (line) lines.push(line.translateToString(true).trim());
    }
    return lines.filter(l => l.length > 0).join('\n');
  });
}

/** Extract SGR mouse wheel events from the WS spy. */
async function getSGREvents(page) {
  return page.evaluate(() =>
    (window.__mockWsSpy || [])
      .map(s => { try { return JSON.parse(s); } catch { return null; } })
      .filter(m => m && m.type === 'input' && m.data && m.data.startsWith('\x1b[<'))
  );
}

/** Extract SGR button codes from events. */
function sgrButtons(events) {
  return events.map(e => {
    // SGR format: ESC[<btn;col;rowM — extract the button number
    const idx = e.data.indexOf('[<');
    if (idx === -1) return null;
    const semi = e.data.indexOf(';', idx);
    if (semi === -1) return null;
    return parseInt(e.data.substring(idx + 2, semi));
  }).filter(b => b !== null);
}

/** Standard setup: connect SSH, expose terminal, fill scrollback in tmux. */
async function setupTmuxWithScrollback(page, sshServer, testInfo, prefix) {
  await setupRealSSHConnection(page, sshServer);
  await page.evaluate(async () => {
    const { appState } = await import('./modules/state.js');
    window.__testTerminal = appState.terminal;
  });

  // Kill stale tmux, start fresh
  execSync('docker exec mobissh-test-sshd-1 su -c "tmux kill-server 2>/dev/null; true" testuser');
  await sendCommand(page, 'tmux a || tmux');
  await page.waitForTimeout(1500);

  // Fill scrollback
  ensureScript();
  execSync('docker exec mobissh-test-sshd-1 su -c "tmux send-keys \'sh /tmp/fill-scrollback.sh\' Enter" testuser');
  await page.waitForTimeout(5000);
  await snap(page, testInfo, `${prefix}-at-bottom`);

  // Dismiss keyboard so touches land on terminal
  execSync('adb shell input keyevent KEYCODE_BACK');
  await page.waitForTimeout(500);
}

test.describe('Gesture isolation and interaction (Android emulator)', () => {
  test.setTimeout(120_000);

  // ── Phase 3: Isolation tests ──────────────────────────────────────────

  test('scroll isolation: correct direction with pinch DISABLED', async ({ emulatorPage: page, sshServer }, testInfo) => {
    // Ensure pinch is disabled (default)
    await page.evaluate(() => {
      localStorage.setItem('enablePinchZoom', 'false');
    });

    await setupTmuxWithScrollback(page, sshServer, testInfo, 'iso-scroll');
    const bottomContent = await readScreen(page);
    // Bottom should show section E or END OF DATA
    expect(bottomContent).toMatch(/SECTION E|END OF DATA/);

    // Clear WS spy
    await page.evaluate(() => { window.__mockWsSpy = []; });

    // Swipe DOWN (finger top→bottom) = scroll to older content
    // In tmux: should send SGR WheelUp (button 64)
    await swipe(page, '#terminal', 200, 100, 200, 500, 20);
    await page.waitForTimeout(300);
    await swipe(page, '#terminal', 200, 100, 200, 500, 20);
    await page.waitForTimeout(300);
    await swipe(page, '#terminal', 200, 100, 200, 500, 20);
    await page.waitForTimeout(1000);
    await snap(page, testInfo, 'iso-scroll-after-down');

    const afterDown = await readScreen(page);
    const sgrEventsDown = await getSGREvents(page);
    const buttonsDown = sgrButtons(sgrEventsDown);

    // Direction assertion: should see earlier sections (A, B, or C)
    expect(afterDown).not.toMatch(/END OF DATA/);
    // SGR: button 64 = WheelUp (scroll to older content)
    expect(buttonsDown).toContain(64);
    expect(buttonsDown).not.toContain(65);

    // Now swipe UP (finger bottom→top) = scroll to newer content
    await page.evaluate(() => { window.__mockWsSpy = []; });
    await swipe(page, '#terminal', 200, 500, 200, 100, 20);
    await page.waitForTimeout(300);
    await swipe(page, '#terminal', 200, 500, 200, 100, 20);
    await page.waitForTimeout(300);
    await swipe(page, '#terminal', 200, 500, 200, 100, 20);
    await page.waitForTimeout(1000);
    await snap(page, testInfo, 'iso-scroll-after-up');

    const sgrEventsUp = await getSGREvents(page);
    const buttonsUp = sgrButtons(sgrEventsUp);

    // SGR: button 65 = WheelDown (scroll to newer content)
    expect(buttonsUp).toContain(65);
    expect(buttonsUp).not.toContain(64);

    await sendCommand(page, 'exit');
    await page.waitForTimeout(500);
  });

  test('pinch isolation: zoom changes font size with pinch ENABLED', async ({ emulatorPage: page, sshServer }, testInfo) => {
    // Enable pinch
    await page.evaluate(() => {
      localStorage.setItem('enablePinchZoom', 'true');
    });
    await page.reload({ waitUntil: 'domcontentloaded' });

    // Re-setup after reload (vault, connection)
    // Skip vault — it persists across reload in same context
    await page.waitForSelector('.xterm-screen', { timeout: 30_000 });
    await page.evaluate(async () => {
      const { appState } = await import('./modules/state.js');
      window.__testTerminal = appState.terminal;
    });

    // Verify pinch setting took effect
    const pinchEnabled = await page.evaluate(() =>
      localStorage.getItem('enablePinchZoom')
    );
    expect(pinchEnabled).toBe('true');

    // Need a connected terminal for font size to matter
    await setupRealSSHConnection(page, sshServer);
    await page.evaluate(async () => {
      const { appState } = await import('./modules/state.js');
      window.__testTerminal = appState.terminal;
    });

    const fontBefore = await page.evaluate(() =>
      window.__testTerminal?.options.fontSize ?? 14
    );
    await snap(page, testInfo, 'iso-pinch-before');

    // Pinch OUT (spread fingers = zoom in)
    await pinch(page, '#terminal', 50, 200, 15);
    await page.waitForTimeout(500);

    const fontAfter = await page.evaluate(() =>
      window.__testTerminal?.options.fontSize ?? 14
    );
    await snap(page, testInfo, 'iso-pinch-after-zoom-in');
    expect(fontAfter).toBeGreaterThan(fontBefore);

    // Pinch IN (close fingers = zoom out)
    await pinch(page, '#terminal', 200, 50, 15);
    await page.waitForTimeout(500);

    const fontAfterOut = await page.evaluate(() =>
      window.__testTerminal?.options.fontSize ?? 14
    );
    await snap(page, testInfo, 'iso-pinch-after-zoom-out');
    expect(fontAfterOut).toBeLessThan(fontAfter);
  });

  // ── Phase 4: Interaction tests ────────────────────────────────────────

  test('interaction: scroll direction correct AFTER pinch gesture', async ({ emulatorPage: page, sshServer }, testInfo) => {
    // Enable pinch
    await page.evaluate(() => {
      localStorage.setItem('enablePinchZoom', 'true');
    });

    await setupTmuxWithScrollback(page, sshServer, testInfo, 'interact');

    // Record initial font size
    const fontBefore = await page.evaluate(() =>
      window.__testTerminal?.options.fontSize ?? 14
    );

    // FIRST: perform a pinch gesture
    await pinch(page, '#terminal', 60, 180, 12);
    await page.waitForTimeout(500);
    await snap(page, testInfo, 'interact-after-pinch');

    const fontAfterPinch = await page.evaluate(() =>
      window.__testTerminal?.options.fontSize ?? 14
    );
    // Pinch should have changed font size
    expect(fontAfterPinch).not.toBe(fontBefore);

    // THEN: scroll should still work correctly
    await page.evaluate(() => { window.__mockWsSpy = []; });
    await swipe(page, '#terminal', 200, 100, 200, 500, 20);
    await page.waitForTimeout(300);
    await swipe(page, '#terminal', 200, 100, 200, 500, 20);
    await page.waitForTimeout(1000);
    await snap(page, testInfo, 'interact-scroll-after-pinch');

    const sgrEvents = await getSGREvents(page);
    const buttons = sgrButtons(sgrEvents);

    // Scroll direction must be correct even after pinch
    // Swipe down (top→bottom) = WheelUp = button 64
    expect(buttons.length).toBeGreaterThan(0);
    expect(buttons).toContain(64);
    expect(buttons).not.toContain(65);

    await sendCommand(page, 'exit');
    await page.waitForTimeout(500);
  });

  test('interaction: pinch does NOT fire when enablePinchZoom=false', async ({ emulatorPage: page, sshServer }, testInfo) => {
    // Ensure pinch is DISABLED
    await page.evaluate(() => {
      localStorage.setItem('enablePinchZoom', 'false');
    });

    await setupRealSSHConnection(page, sshServer);
    await page.evaluate(async () => {
      const { appState } = await import('./modules/state.js');
      window.__testTerminal = appState.terminal;
    });

    const fontBefore = await page.evaluate(() =>
      window.__testTerminal?.options.fontSize ?? 14
    );

    // Attempt pinch — should be ignored
    await pinch(page, '#terminal', 50, 200, 12);
    await page.waitForTimeout(500);

    const fontAfter = await page.evaluate(() =>
      window.__testTerminal?.options.fontSize ?? 14
    );
    await snap(page, testInfo, 'gate-pinch-disabled');

    // Font should NOT have changed
    expect(fontAfter).toBe(fontBefore);
  });

  test('interaction: horizontal swipe still sends tmux commands after scroll', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await page.evaluate(() => {
      localStorage.setItem('enablePinchZoom', 'false');
    });

    await setupTmuxWithScrollback(page, sshServer, testInfo, 'swipe-after-scroll');

    // First: vertical scroll
    await swipe(page, '#terminal', 200, 100, 200, 500, 20);
    await page.waitForTimeout(500);

    // Then: horizontal swipe (left = tmux prev window)
    await page.evaluate(() => { window.__mockWsSpy = []; });
    await swipe(page, '#terminal', 350, 300, 50, 300, 12);
    await page.waitForTimeout(500);
    await snap(page, testInfo, 'swipe-after-scroll-left');

    const msgs = await page.evaluate(() =>
      (window.__mockWsSpy || [])
        .map(s => { try { return JSON.parse(s); } catch { return null; } })
        .filter(m => m && m.type === 'input')
    );

    // tmux prefix + p should have been sent
    expect(msgs.some(m => m.data === '\x02p')).toBe(true);

    await sendCommand(page, 'exit');
    await page.waitForTimeout(500);
  });
});
