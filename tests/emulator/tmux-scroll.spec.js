/**
 * tests/emulator/tmux-scroll.spec.js
 *
 * Integration tests for vertical swipe scrolling on Android emulator.
 * Tests scrolling both inside tmux (server-side, SGR mouse events) and
 * outside tmux (client-side, xterm.js viewportY).
 *
 * Uses `adb shell input swipe` for real Android touch events that go
 * through Chrome's full input pipeline (kernel > compositor > DOM).
 */
const {
  test, expect, screenshot, setupRealSSHConnection, sendCommand,
  adbSwipe, dismissKeyboard, ensureKeyboardDismissed,
  warmupTouch, getVisibleTerminalBounds,
  swipeToOlderContent, swipeToNewerContent, expectedSGRButton,
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

// adbSwipe imported from fixtures

/** Read what the user sees.
 *  viewportY mode: reads at viewportY (for client-side xterm.js scroll, outside tmux)
 *  baseY mode: reads at baseY (for server-side tmux scroll) */
async function readScreen(page, useViewport = false) {
  return page.evaluate((vp) => {
    const term = window.__testTerminal;
    if (!term) return '';
    const buf = term.buffer.active;
    const startY = vp ? buf.viewportY : buf.baseY;
    const lines = [];
    for (let i = 0; i < term.rows; i++) {
      const line = buf.getLine(startY + i);
      if (line) lines.push(line.translateToString(true).trim());
    }
    return lines.filter(l => l.length > 0).join('\n');
  }, useViewport);
}

/** Read xterm.js viewport scroll position (client-side). */
async function readViewportY(page) {
  return page.evaluate(() => {
    const term = window.__testTerminal;
    if (!term) return { viewportY: 0, baseY: 0 };
    const buf = term.buffer.active;
    return { viewportY: buf.viewportY, baseY: buf.baseY };
  });
}

/** Copy fill-scrollback.sh to the SSH container. */
function ensureScript() {
  execSync(`docker cp "${FILL_SCRIPT}" mobissh-test-sshd-1:/tmp/fill-scrollback.sh`);
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

/** Perform 3 consecutive intent-based swipes. Returns screen content and SGR mouse events.
 *  direction: 'older' or 'newer' — physical swipe direction computed from scroll setting.
 *  useViewport: true for client-side scroll (plain shell), false for server-side (tmux). */
async function swipeAndCapture(page, testInfo, label, direction, useViewport = false) {
  const bounds = await getVisibleTerminalBounds(page);
  expect(bounds).not.toBeNull();
  const swipeFn = direction === 'older' ? swipeToOlderContent : swipeToNewerContent;
  await page.evaluate(() => { window.__mockWsSpy = []; });

  await swipeFn(page, bounds);
  await page.waitForTimeout(500);
  await swipeFn(page, bounds);
  await page.waitForTimeout(500);
  await swipeFn(page, bounds);
  await page.waitForTimeout(2000);
  await snap(page, testInfo, label);

  const content = await readScreen(page, useViewport);
  const viewport = await readViewportY(page);
  const sgrEvents = await page.evaluate(() =>
    (window.__mockWsSpy || [])
      .map(s => { try { return JSON.parse(s); } catch { return null; } })
      .filter(m => m && m.type === 'input' && m.data && m.data.startsWith('\x1b[<'))
  );

  return { content, sgrEvents, viewport };
}

test.describe('vertical scroll (Android emulator + real SSH)', () => {
  test.setTimeout(120_000);

  test('plain shell: swipe scrolls xterm.js viewport', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await setupRealSSHConnection(page, sshServer);
    await page.evaluate(async () => {
      const { appState } = await import('./modules/state.js');
      window.__testTerminal = appState.terminal;
    });

    // Fill scrollback outside tmux via sendCommand
    ensureScript();
    await sendCommand(page, 'sh /tmp/fill-scrollback.sh');
    await page.waitForTimeout(5000);
    await snap(page, testInfo, 'plain-01-at-bottom');

    const bottomContent = await readScreen(page, true);
    const bottomViewport = await readViewportY(page);

    // Dismiss keyboard and prime ADB touch pipeline
    await ensureKeyboardDismissed(page);
    const warmupBounds = await getVisibleTerminalBounds(page);
    warmupTouch(warmupBounds);
    await page.waitForTimeout(500);

    // Intent: scroll to older content (client-side scroll)
    const { content: afterUp, viewport: vpUp } = await swipeAndCapture(
      page, testInfo, 'plain-02-scroll-older', 'older', true);

    // Intent: scroll to newer content
    const { content: afterDown, viewport: vpDown } = await swipeAndCapture(
      page, testInfo, 'plain-03-scroll-newer', 'newer', true);

    // Intent: scroll to older again
    const { content: afterUp2 } = await swipeAndCapture(
      page, testInfo, 'plain-04-scroll-older-2', 'older', true);

    // Outside tmux, xterm.js viewportY changes (client-side scroll)
    expect(vpUp.viewportY).toBeLessThan(bottomViewport.baseY);
    // Content changes with scroll position
    expect(afterUp).not.toBe(bottomContent);
    expect(afterDown).not.toBe(afterUp);
    expect(afterUp === afterDown && afterDown === afterUp2).toBe(false);
  });

  test('tmux: swipe up, down, up produces three distinct viewport positions', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await setupRealSSHConnection(page, sshServer);
    await page.evaluate(async () => {
      const { appState } = await import('./modules/state.js');
      window.__testTerminal = appState.terminal;
    });

    // Kill stale tmux, start fresh
    execSync('docker exec mobissh-test-sshd-1 su -c "tmux kill-server 2>/dev/null; true" testuser');
    await sendCommand(page, 'tmux a || tmux');
    await page.waitForTimeout(1500);
    await snap(page, testInfo, 'tmux-01-attached');

    // Fill scrollback via tmux send-keys
    ensureScript();
    execSync('docker exec mobissh-test-sshd-1 su -c "tmux send-keys \'sh /tmp/fill-scrollback.sh\' Enter" testuser');
    await page.waitForTimeout(5000);
    await snap(page, testInfo, 'tmux-02-at-bottom');
    const bottomContent = await readScreen(page);

    // Dismiss keyboard and prime ADB touch pipeline
    await ensureKeyboardDismissed(page);
    const warmupBounds = await getVisibleTerminalBounds(page);
    warmupTouch(warmupBounds);
    await page.waitForTimeout(500);

    // Intent: older, newer, older
    const { content: afterUp1, sgrEvents } = await swipeAndCapture(
      page, testInfo, 'tmux-03-scroll-older', 'older');

    const { content: afterDown } = await swipeAndCapture(
      page, testInfo, 'tmux-04-scroll-newer', 'newer');

    const { content: afterUp2 } = await swipeAndCapture(
      page, testInfo, 'tmux-05-scroll-older-2', 'older');

    // In tmux: SGR mouse wheel events sent to SSH
    expect(sgrEvents.length).toBeGreaterThan(0);

    // Direction-aware SGR: scrolling to older = WheelUp button
    const { older, newer } = expectedSGRButton();
    const buttonsUp1 = sgrButtons(sgrEvents);
    expect(buttonsUp1).toContain(older);
    expect(buttonsUp1).not.toContain(newer);

    // Content should have moved away from the bottom
    expect(afterUp1).not.toBe(bottomContent);
    expect(afterUp1).not.toMatch(/END OF DATA/);

    // Swipe down should return toward newer content
    expect(afterDown).not.toBe(afterUp1);

    // Three positions should not all be the same
    expect(afterUp1 === afterDown && afterDown === afterUp2).toBe(false);

    await sendCommand(page, 'exit');
    await page.waitForTimeout(500);
  });

  test('tmux: swipe scrolls with on-screen keyboard visible', async ({ emulatorPage: page, sshServer }, testInfo) => {
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
    await snap(page, testInfo, 'kb-on-01-at-bottom');
    const bottomContent = await readScreen(page);

    // Focus input to raise keyboard: JS focus + ADB tap on the terminal area.
    // JS focus alone may not trigger the soft keyboard; the ADB tap ensures
    // Android's InputMethodManager shows it.
    await page.evaluate(() => {
      const el = document.getElementById('directInput') || document.getElementById('imeInput');
      if (el) { el.focus(); el.click(); }
    });
    await page.waitForTimeout(500);
    // ADB tap on terminal to trigger keyboard through Android input pipeline
    const preBounds = await getVisibleTerminalBounds(page);
    if (preBounds) adbSwipe(preBounds.centerX, preBounds.top + 50, preBounds.centerX, preBounds.top + 50, 50);
    await page.waitForTimeout(2000);
    await snap(page, testInfo, 'kb-on-02-keyboard-check');

    // Get visible terminal bounds WITH keyboard showing
    const bounds = await getVisibleTerminalBounds(page);
    expect(bounds).not.toBeNull();
    expect(bounds.keyboardVisible).toBe(true);

    // Prime ADB touch pipeline (keyboard stays visible — warmup within terminal bounds)
    warmupTouch(bounds);
    await page.waitForTimeout(500);

    // Intent: older, newer, older — swipe helpers confine to visible bounds
    const { content: afterUp, sgrEvents } = await swipeAndCapture(
      page, testInfo, 'kb-on-03-scroll-older', 'older');

    const { content: afterDown } = await swipeAndCapture(
      page, testInfo, 'kb-on-04-scroll-newer', 'newer');

    const { content: afterUp2 } = await swipeAndCapture(
      page, testInfo, 'kb-on-05-scroll-older-2', 'older');

    // SGR events should still be sent even with keyboard visible
    expect(sgrEvents.length).toBeGreaterThan(0);

    // Direction-aware SGR: scrolling to older = WheelUp button
    const { older, newer } = expectedSGRButton();
    const buttonsUp = sgrButtons(sgrEvents);
    expect(buttonsUp).toContain(older);
    expect(buttonsUp).not.toContain(newer);

    expect(afterUp).not.toBe(bottomContent);
    expect(afterUp).not.toMatch(/END OF DATA/);
    expect(afterDown).not.toBe(afterUp);
    expect(afterUp === afterDown && afterDown === afterUp2).toBe(false);

    await sendCommand(page, 'exit');
    await page.waitForTimeout(500);
  });
});
