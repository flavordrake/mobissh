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

function adbSwipe(x1, y1, x2, y2, durationMs = 300) {
  execSync(`adb shell input swipe ${x1} ${y1} ${x2} ${y2} ${durationMs}`);
}

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

/** Perform 3 consecutive swipes. Returns screen content and SGR mouse events.
 *  useViewport: true for client-side scroll (plain shell), false for server-side (tmux). */
async function swipeAndCapture(page, testInfo, label, y1, y2, useViewport = false) {
  const cx = 540;
  await page.evaluate(() => { window.__mockWsSpy = []; });

  adbSwipe(cx, y1, cx, y2, 600);
  await page.waitForTimeout(500);
  adbSwipe(cx, y1, cx, y2, 600);
  await page.waitForTimeout(500);
  adbSwipe(cx, y1, cx, y2, 600);
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

    // Dismiss keyboard
    execSync('adb shell input keyevent KEYCODE_BACK');
    await page.waitForTimeout(500);

    // Swipe UP (finger down) — scroll back through output (client-side scroll)
    const { content: afterUp, viewport: vpUp } = await swipeAndCapture(
      page, testInfo, 'plain-02-scroll-up', 300, 1200, true);

    // Swipe DOWN (finger up) — scroll forward
    const { content: afterDown, viewport: vpDown } = await swipeAndCapture(
      page, testInfo, 'plain-03-scroll-down', 1200, 300, true);

    // Swipe UP again
    const { content: afterUp2 } = await swipeAndCapture(
      page, testInfo, 'plain-04-scroll-up-2', 300, 1200, true);

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

    // Dismiss keyboard
    execSync('adb shell input keyevent KEYCODE_BACK');
    await page.waitForTimeout(500);

    // Swipe UP, DOWN, UP
    const { content: afterUp1, sgrEvents } = await swipeAndCapture(
      page, testInfo, 'tmux-03-scroll-up', 300, 1200);

    const { content: afterDown } = await swipeAndCapture(
      page, testInfo, 'tmux-04-scroll-down', 1200, 300);

    const { content: afterUp2 } = await swipeAndCapture(
      page, testInfo, 'tmux-05-scroll-up-2', 300, 1200);

    // In tmux: SGR mouse wheel events sent to SSH
    expect(sgrEvents.length).toBeGreaterThan(0);

    // Direction-aware: swipe UP (y 300→1200) = finger down = scroll to older
    // SGR WheelUp = button 64; should NOT contain button 65
    const buttonsUp1 = sgrButtons(sgrEvents);
    expect(buttonsUp1).toContain(64);
    expect(buttonsUp1).not.toContain(65);

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

    // Tap terminal to ensure keyboard is raised
    execSync('adb shell input tap 540 600');
    await page.waitForTimeout(1500);
    await snap(page, testInfo, 'kb-on-02-keyboard-check');

    // Swipe in narrower zone above potential keyboard
    const { content: afterUp, sgrEvents } = await swipeAndCapture(
      page, testInfo, 'kb-on-03-scroll-up', 300, 1050);

    const { content: afterDown } = await swipeAndCapture(
      page, testInfo, 'kb-on-04-scroll-down', 1050, 300);

    const { content: afterUp2 } = await swipeAndCapture(
      page, testInfo, 'kb-on-05-scroll-up-2', 300, 1050);

    // SGR events should still be sent even with keyboard visible
    expect(sgrEvents.length).toBeGreaterThan(0);

    // Direction-aware: swipe UP (y 300→1050) = scroll to older = button 64
    const buttonsUp = sgrButtons(sgrEvents);
    expect(buttonsUp).toContain(64);
    expect(buttonsUp).not.toContain(65);

    expect(afterUp).not.toBe(bottomContent);
    expect(afterUp).not.toMatch(/END OF DATA/);
    expect(afterDown).not.toBe(afterUp);
    expect(afterUp === afterDown && afterDown === afterUp2).toBe(false);

    await sendCommand(page, 'exit');
    await page.waitForTimeout(500);
  });
});
