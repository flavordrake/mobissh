/**
 * tests/appium/gesture-multi-feature.spec.js
 *
 * Multi-feature gesture test: exercises vertical scroll, horizontal swipe,
 * and pinch-to-zoom in the same Appium session to verify they don't interfere.
 *
 * NOT a frozen baseline — this is an active feature test.
 *
 * Test 3 (pinch default) deliberately does NOT set enablePinchZoom=true in
 * localStorage. It relies on the default being enabled (#160). If the default
 * is still disabled, tests 3 and 5 will FAIL.
 *
 * Requires: Android emulator, Appium server, Docker test-sshd, MobiSSH server.
 */

const { execSync } = require('child_process');
const path = require('path');
const {
  test, expect,
  swipeToOlderContent, swipeToNewerContent: _swipeToNewerContent, warmupSwipes,
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

/** Extract input messages from WS spy. */
async function getWsInputMessages(driver) {
  return driver.executeScript(`
    return (window.__mockWsSpy || [])
      .map(s => { try { return JSON.parse(s); } catch { return null; } })
      .filter(m => m && m.type === 'input');
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

/**
 * Perform a two-finger pinch gesture via W3C Actions.
 * @param {object} driver - WebDriverIO session
 * @param {number} centerX - Center X in screen pixels
 * @param {number} centerY - Center Y in screen pixels
 * @param {number} startGap - Initial distance between fingers (px)
 * @param {number} endGap - Final distance between fingers (px)
 */
async function performPinch(driver, centerX, centerY, startGap, endGap) {
  const steps = 10;
  const halfStart = Math.round(startGap / 2);
  const halfEnd = Math.round(endGap / 2);

  const finger1Actions = [
    { type: 'pointerMove', duration: 0, x: centerX - halfStart, y: centerY, origin: 'viewport' },
    { type: 'pointerDown', button: 0 },
    { type: 'pause', duration: 100 },
  ];
  const finger2Actions = [
    { type: 'pointerMove', duration: 0, x: centerX + halfStart, y: centerY, origin: 'viewport' },
    { type: 'pointerDown', button: 0 },
    { type: 'pause', duration: 100 },
  ];

  for (let i = 1; i <= steps; i++) {
    const f = i / steps;
    const offset1 = Math.round(halfStart + (halfEnd - halfStart) * f);
    const offset2 = Math.round(halfStart + (halfEnd - halfStart) * f);
    finger1Actions.push({
      type: 'pointerMove', duration: 50,
      x: centerX - offset1, y: centerY, origin: 'viewport',
    });
    finger2Actions.push({
      type: 'pointerMove', duration: 50,
      x: centerX + offset2, y: centerY, origin: 'viewport',
    });
  }

  finger1Actions.push({ type: 'pointerUp', button: 0 });
  finger2Actions.push({ type: 'pointerUp', button: 0 });

  await switchToNative(driver);
  await driver.performActions([
    { type: 'pointer', id: 'finger1', parameters: { pointerType: 'touch' }, actions: finger1Actions },
    { type: 'pointer', id: 'finger2', parameters: { pointerType: 'touch' }, actions: finger2Actions },
  ]);
  await driver.releaseActions();
  await switchToWebview(driver);
  await driver.pause(1000);
}

/** Read the current terminal font size. */
async function getFontSize(driver) {
  return driver.executeScript(
    'return window.__testTerminal?.options.fontSize ?? 14', []);
}

test.describe('Multi-feature gestures (Appium)', () => {
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

  test('vertical scroll moves through scrollback in tmux', async ({ driver }, testInfo) => {
    await setupTmuxWithScrollback(driver, testInfo, 'scroll');

    // Verify we start at the bottom
    const bottomContent = await readScreen(driver);
    expect(bottomContent).toMatch(/SECTION E|END OF DATA/);

    const bounds = await getVisibleTerminalBounds(driver);
    await warmupSwipes(driver, bounds);

    // Scroll to older
    for (let i = 0; i < 3; i++) {
      await swipeToOlderContent(driver, bounds);
      await driver.pause(500);
    }
    await driver.pause(1500);
    await attachScreenshot(driver, testInfo, 'scroll-after-older');

    const olderContent = await readScreen(driver, false);
    expect(olderContent).not.toMatch(/END OF DATA/);
    expect(olderContent).not.toBe(bottomContent);
  });

  test('horizontal swipe switches tmux windows', async ({ driver }, testInfo) => {
    await setupTmuxWithScrollback(driver, testInfo, 'hswipe');

    // Add a second tmux window with a marker
    dockerExec('su -c "tmux new-window" testuser');
    await driver.pause(500);
    dockerExec('su -c "tmux send-keys \'echo WINDOW_TWO\' Enter" testuser');
    await driver.pause(500);
    dockerExec('su -c "tmux select-window -t 0" testuser');
    await driver.pause(500);
    await attachScreenshot(driver, testInfo, 'hswipe-window0');

    const bounds = await getVisibleTerminalBounds(driver);
    expect(bounds).not.toBeNull();

    // Horizontal swipe RIGHT (natural default: finger right = next window = \x02n)
    await driver.executeScript('window.__mockWsSpy = []', []);
    const margin = (bounds.right - bounds.left) * 0.15;
    const centerY = Math.round((bounds.top + bounds.bottom) / 2);
    await appiumSwipe(driver,
      bounds.left + margin, centerY,
      bounds.right - margin, centerY,
      15, 40);
    await driver.pause(1000);
    await attachScreenshot(driver, testInfo, 'hswipe-after-right');

    let msgs = await getWsInputMessages(driver);
    expect(msgs.some(m => m.data === '\x02n')).toBe(true);

    // Horizontal swipe LEFT (natural default: finger left = prev window = \x02p)
    await driver.executeScript('window.__mockWsSpy = []', []);
    await appiumSwipe(driver,
      bounds.right - margin, centerY,
      bounds.left + margin, centerY,
      15, 40);
    await driver.pause(1000);
    await attachScreenshot(driver, testInfo, 'hswipe-after-left');

    msgs = await getWsInputMessages(driver);
    expect(msgs.some(m => m.data === '\x02p')).toBe(true);
  });

  test('pinch-to-zoom changes font size with default settings', async ({ driver }, testInfo) => {
    await setupRealSSHConnection(driver);
    await exposeTerminal(driver);

    // enablePinchZoom should NOT be explicitly set — relies on default (#160)
    const pinchSetting = await driver.executeScript(
      "return localStorage.getItem('enablePinchZoom')", []);
    expect(pinchSetting).toBeNull();

    const fontBefore = await getFontSize(driver);
    await attachScreenshot(driver, testInfo, 'pinch-before');

    await dismissKeyboardViaBack(driver);
    const bounds = await getVisibleTerminalBounds(driver);
    expect(bounds).not.toBeNull();

    const centerY = Math.round((bounds.top + bounds.bottom) / 2);

    // Pinch OPEN (spread fingers = zoom in = increase font size)
    await performPinch(driver, bounds.centerX, centerY, 100, 350);
    await attachScreenshot(driver, testInfo, 'pinch-after-open');

    const fontAfterOpen = await getFontSize(driver);
    expect(fontAfterOpen).toBeGreaterThan(fontBefore);

    // Verify persisted to localStorage
    const storedSize = await driver.executeScript(
      "return parseInt(localStorage.getItem('fontSize') || '0')", []);
    expect(storedSize).toBe(fontAfterOpen);

    // Pinch CLOSE (fingers together = zoom out = decrease font size)
    await performPinch(driver, bounds.centerX, centerY, 350, 100);
    await attachScreenshot(driver, testInfo, 'pinch-after-close');

    const fontAfterClose = await getFontSize(driver);
    expect(fontAfterClose).toBeLessThan(fontAfterOpen);
  });

  test('pinch-to-zoom blocked when explicitly disabled', async ({ driver }, testInfo) => {
    await driver.executeScript(
      "localStorage.setItem('enablePinchZoom', 'false')", []);
    await driver.url(BASE_URL);
    await driver.pause(2000);
    await dismissNativeDialogs(driver);
    await switchToWebview(driver);
    await setupVault(driver);
    await driver.executeScript(
      "document.querySelector('[data-panel=\"terminal\"]')?.click()", []);
    await driver.pause(500);

    await setupRealSSHConnection(driver);
    await exposeTerminal(driver);

    const fontBefore = await getFontSize(driver);
    await attachScreenshot(driver, testInfo, 'pinch-disabled-before');

    await dismissKeyboardViaBack(driver);
    const bounds = await getVisibleTerminalBounds(driver);
    expect(bounds).not.toBeNull();

    const centerY = Math.round((bounds.top + bounds.bottom) / 2);

    // Attempt pinch open — should have no effect
    await performPinch(driver, bounds.centerX, centerY, 100, 350);
    await attachScreenshot(driver, testInfo, 'pinch-disabled-after');

    const fontAfter = await getFontSize(driver);
    expect(fontAfter).toBe(fontBefore);
  });

  test('all gestures in one session without interference', async ({ driver }, testInfo) => {
    await setupTmuxWithScrollback(driver, testInfo, 'combo');

    // Add second tmux window for horizontal swipe
    dockerExec('su -c "tmux new-window" testuser');
    await driver.pause(500);
    dockerExec('su -c "tmux send-keys \'echo WINDOW_TWO\' Enter" testuser');
    await driver.pause(500);
    dockerExec('su -c "tmux select-window -t 0" testuser');
    await driver.pause(500);

    const bounds = await getVisibleTerminalBounds(driver);
    expect(bounds).not.toBeNull();
    await warmupSwipes(driver, bounds);

    // 1. Vertical scroll to older
    const bottomContent = await readScreen(driver);
    for (let i = 0; i < 3; i++) {
      await swipeToOlderContent(driver, bounds);
      await driver.pause(500);
    }
    await driver.pause(1500);
    await attachScreenshot(driver, testInfo, 'combo-after-scroll');

    const olderContent = await readScreen(driver, false);
    expect(olderContent).not.toBe(bottomContent);

    // 2. Horizontal swipe right (next window)
    await driver.executeScript('window.__mockWsSpy = []', []);
    const margin = (bounds.right - bounds.left) * 0.15;
    const centerY = Math.round((bounds.top + bounds.bottom) / 2);
    await appiumSwipe(driver,
      bounds.left + margin, centerY,
      bounds.right - margin, centerY,
      15, 40);
    await driver.pause(1000);
    await attachScreenshot(driver, testInfo, 'combo-after-hswipe-right');

    let msgs = await getWsInputMessages(driver);
    expect(msgs.some(m => m.data === '\x02n')).toBe(true);

    // 3. Horizontal swipe left (prev window)
    await driver.executeScript('window.__mockWsSpy = []', []);
    await appiumSwipe(driver,
      bounds.right - margin, centerY,
      bounds.left + margin, centerY,
      15, 40);
    await driver.pause(1000);
    await attachScreenshot(driver, testInfo, 'combo-after-hswipe-left');

    msgs = await getWsInputMessages(driver);
    expect(msgs.some(m => m.data === '\x02p')).toBe(true);

    // 4. Pinch open (zoom in) — relies on #160 default
    const fontBefore = await getFontSize(driver);
    await performPinch(driver, bounds.centerX, centerY, 100, 350);
    await attachScreenshot(driver, testInfo, 'combo-after-pinch-open');

    const fontAfterOpen = await getFontSize(driver);
    expect(fontAfterOpen).toBeGreaterThan(fontBefore);

    // 5. Pinch close (zoom out)
    await performPinch(driver, bounds.centerX, centerY, 350, 100);
    await attachScreenshot(driver, testInfo, 'combo-after-pinch-close');

    const fontAfterClose = await getFontSize(driver);
    expect(fontAfterClose).toBeLessThan(fontAfterOpen);
  });
});
