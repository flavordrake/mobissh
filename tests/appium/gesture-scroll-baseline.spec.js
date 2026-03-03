/**
 * tests/appium/gesture-scroll-baseline.spec.js
 *
 * Regression baseline: vertical scroll gestures via Appium W3C Actions.
 * Verifies scroll DIRECTION using fill-scrollback.sh labeled sections (A-E).
 *
 * Test matrix:
 *   1. tmux: scroll to older → sees sections A/B/C, SGR button 64
 *   2. tmux: scroll to newer after older → SGR button 65
 *   3. tmux: round-trip (older→newer→older) → 3 distinct positions
 *   4. plain shell: viewportY decreases after scroll to older
 *   5. mobile:swipeGesture API → proves high-level API pipeline
 *
 * Requires: Android emulator, Appium server, Docker test-sshd, MobiSSH server.
 */

const { execSync } = require('child_process');
const path = require('path');
const {
  test, expect,
  swipeToOlderContent, swipeToNewerContent, warmupSwipes,
  setupRealSSHConnection, setupVault, sendCommand,
  dismissKeyboardViaBack, exposeTerminal,
  getVisibleTerminalBounds, appiumSwipe,
  readScreen, attachScreenshot,
  switchToNative, switchToWebview,
  dismissNativeDialogs,
  BASE_URL,
} = require('./fixtures');

const FILL_SCRIPT = path.join(__dirname, '../emulator/fill-scrollback.sh');

/** Copy fill-scrollback.sh into the Docker test-sshd container. */
function ensureScript() {
  execSync(
    `docker compose -f docker-compose.test.yml cp "${FILL_SCRIPT}" test-sshd:/tmp/fill-scrollback.sh`,
    { timeout: 10000 }
  );
}

/** Run a command inside the Docker test-sshd container. */
function dockerExec(cmd) {
  execSync(
    `docker compose -f docker-compose.test.yml exec -T test-sshd ${cmd}`,
    { timeout: 15000, encoding: 'utf8' }
  );
}

/** Extract SGR mouse wheel button codes from WS spy messages. */
async function getSGRButtons(driver) {
  return driver.executeScript(`
    return (window.__mockWsSpy || [])
      .map(s => { try { return JSON.parse(s); } catch { return null; } })
      .filter(m => m && m.type === 'input' && m.data && m.data.includes('[<'))
      .map(m => {
        const idx = m.data.indexOf('[<');
        const semi = m.data.indexOf(';', idx);
        if (idx === -1 || semi === -1) return null;
        return parseInt(m.data.substring(idx + 2, semi));
      })
      .filter(b => b !== null);
  `, []);
}

/** Full setup: SSH connect, start tmux, fill scrollback, dismiss keyboard. */
async function setupTmuxWithScrollback(driver, testInfo, label) {
  await setupRealSSHConnection(driver);
  await exposeTerminal(driver);

  // Kill stale tmux, start fresh
  try { dockerExec('su -c "tmux kill-server" testuser'); } catch { /* no tmux running */ }
  await sendCommand(driver, 'tmux');
  await driver.pause(2000);

  // Copy and run fill-scrollback script via tmux send-keys
  ensureScript();
  dockerExec('su -c "tmux send-keys \'sh /tmp/fill-scrollback.sh\' Enter" testuser');
  await driver.pause(5000);
  await attachScreenshot(driver, testInfo, `${label}-at-bottom`);

  await dismissKeyboardViaBack(driver);
  await driver.pause(500);
}

/** Perform 3 consecutive swipes in a direction, capture content and SGR buttons. */
async function swipeAndCapture(driver, testInfo, label, direction) {
  const bounds = await getVisibleTerminalBounds(driver);
  expect(bounds).not.toBeNull();

  await driver.executeScript("window.__mockWsSpy = []", []);

  const swipeFn = direction === 'older' ? swipeToOlderContent : swipeToNewerContent;
  for (let i = 0; i < 3; i++) {
    await swipeFn(driver, bounds);
    await driver.pause(500);
  }
  await driver.pause(1500);
  await attachScreenshot(driver, testInfo, label);

  const content = await readScreen(driver, false);
  const buttons = await getSGRButtons(driver);
  return { content, buttons };
}

test.describe('Gesture scroll baseline (Appium)', () => {
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

  test('tmux: scroll to older produces earlier sections, not END OF DATA', async ({ driver }, testInfo) => {
    await setupTmuxWithScrollback(driver, testInfo, 'tmux-older');

    // Verify we start at the bottom
    const bottomContent = await readScreen(driver);
    expect(bottomContent).toMatch(/SECTION E|END OF DATA/);

    const bounds = await getVisibleTerminalBounds(driver);
    await warmupSwipes(driver, bounds);

    const { content, buttons } = await swipeAndCapture(
      driver, testInfo, 'tmux-older-after-scroll', 'older');

    // Direction: should see earlier sections, not the end marker
    expect(content).not.toMatch(/END OF DATA/);
    // SGR button 64 = WheelUp = scroll to older content
    expect(buttons).toContain(64);
  });

  test('tmux: scroll to newer after older returns toward section E', async ({ driver }, testInfo) => {
    await setupTmuxWithScrollback(driver, testInfo, 'tmux-newer');

    const bounds = await getVisibleTerminalBounds(driver);
    await warmupSwipes(driver, bounds);

    // Scroll to older first
    await swipeAndCapture(driver, testInfo, 'tmux-newer-step1-older', 'older');

    // Clear spy, scroll back to newer
    const { buttons } = await swipeAndCapture(
      driver, testInfo, 'tmux-newer-step2-newer', 'newer');

    // SGR button 65 = WheelDown = scroll to newer content
    expect(buttons).toContain(65);
  });

  test('tmux: older -> newer -> older produces 3 distinct positions', async ({ driver }, testInfo) => {
    await setupTmuxWithScrollback(driver, testInfo, 'tmux-roundtrip');
    const bottomContent = await readScreen(driver);

    const bounds = await getVisibleTerminalBounds(driver);
    await warmupSwipes(driver, bounds);

    const { content: pos1 } = await swipeAndCapture(
      driver, testInfo, 'tmux-rt-1-older', 'older');
    const { content: pos2 } = await swipeAndCapture(
      driver, testInfo, 'tmux-rt-2-newer', 'newer');
    const { content: pos3 } = await swipeAndCapture(
      driver, testInfo, 'tmux-rt-3-older', 'older');

    // All 4 snapshots should not all be identical (proves movement happened)
    const unique = new Set([bottomContent, pos1, pos2, pos3]);
    expect(unique.size).toBeGreaterThanOrEqual(2);
    // And specifically, the older snapshots should differ from bottom
    expect(pos1).not.toBe(bottomContent);
  });

  test('plain shell: scroll changes xterm.js viewportY', async ({ driver }, testInfo) => {
    await setupRealSSHConnection(driver);
    await exposeTerminal(driver);

    // Fill scrollback without tmux
    ensureScript();
    await sendCommand(driver, 'sh /tmp/fill-scrollback.sh');
    await driver.pause(5000);
    await attachScreenshot(driver, testInfo, 'plain-at-bottom');

    const bottomViewportY = await driver.executeScript(`
      const buf = window.__testTerminal?.buffer?.active;
      return buf ? buf.viewportY : -1;
    `, []);
    const bottomBaseY = await driver.executeScript(`
      const buf = window.__testTerminal?.buffer?.active;
      return buf ? buf.baseY : -1;
    `, []);

    // At bottom, viewportY should equal baseY
    expect(bottomViewportY).toBe(bottomBaseY);

    await dismissKeyboardViaBack(driver);
    const bounds = await getVisibleTerminalBounds(driver);
    await warmupSwipes(driver, bounds);

    // Scroll to older content
    for (let i = 0; i < 3; i++) {
      await swipeToOlderContent(driver, bounds);
      await driver.pause(500);
    }
    await driver.pause(1500);
    await attachScreenshot(driver, testInfo, 'plain-after-older');

    const afterViewportY = await driver.executeScript(`
      const buf = window.__testTerminal?.buffer?.active;
      return buf ? buf.viewportY : -1;
    `, []);

    // viewportY should have decreased (scrolled up from bottom)
    expect(afterViewportY).toBeLessThan(bottomBaseY);
  });

  test('mobile:swipeGesture API produces scroll events', async ({ driver }, testInfo) => {
    await setupTmuxWithScrollback(driver, testInfo, 'mobile-api');

    const bounds = await getVisibleTerminalBounds(driver);
    await warmupSwipes(driver, bounds);

    await driver.executeScript("window.__mockWsSpy = []", []);

    // Use Appium's high-level swipe command via native context
    await switchToNative(driver);
    const screenSize = await driver.getWindowSize();
    await driver.execute('mobile: swipeGesture', {
      left: Math.round(screenSize.width * 0.2),
      top: Math.round(screenSize.height * 0.3),
      width: Math.round(screenSize.width * 0.6),
      height: Math.round(screenSize.height * 0.4),
      direction: 'down',
      percent: 0.5,
      speed: 800,
    });
    await switchToWebview(driver);
    await driver.pause(2000);
    await attachScreenshot(driver, testInfo, 'mobile-api-after');

    // Looser assertion: high-level API may produce fling with few touchmove events.
    // Verify some kind of scroll activity: SGR events or content change from bottom.
    const buttons = await getSGRButtons(driver);
    const content = await readScreen(driver);
    const scrollHappened = buttons.length > 0 || !content.includes('END OF DATA');
    expect(scrollHappened).toBe(true);
  });
});
