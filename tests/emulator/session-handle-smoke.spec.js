/**
 * tests/emulator/session-handle-smoke.spec.js
 *
 * Emulator smoke tests for SessionHandle terminal sizing (#374).
 * Validates that terminal width is correct after connect, panel switch,
 * and app background/resume on real Android hardware.
 *
 * RED baseline: current code has resize bugs that these tests expose.
 *
 * Run: scripts/run-emulator-tests.sh tests/emulator/session-handle-smoke.spec.js
 */

const { test, expect, screenshot, setupRealSSHConnection,
  ensureKeyboardDismissed } = require('./fixtures');
const { execSync } = require('child_process');

test.describe('SessionHandle terminal sizing (#374)', () => {

  test('after connecting, terminal width > 80% of viewport', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await setupRealSSHConnection(page, sshServer);
    await ensureKeyboardDismissed(page);
    await page.waitForTimeout(500);

    await screenshot(page, testInfo, '01-connected');

    const metrics = await page.evaluate(() => {
      const screen = document.querySelector('.xterm-screen');
      if (!screen) return null;
      const rect = screen.getBoundingClientRect();
      const vpWidth = window.innerWidth;
      return { termWidth: rect.width, vpWidth, ratio: rect.width / vpWidth };
    });

    expect(metrics).not.toBeNull();
    expect(metrics.ratio).toBeGreaterThan(0.8);
  });

  test('after navigating to Connect panel and back, terminal width unchanged', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await setupRealSSHConnection(page, sshServer);
    await ensureKeyboardDismissed(page);
    await page.waitForTimeout(500);

    // Measure initial terminal width
    const initialWidth = await page.evaluate(() => {
      const screen = document.querySelector('.xterm-screen');
      return screen ? screen.getBoundingClientRect().width : 0;
    });
    expect(initialWidth).toBeGreaterThan(0);

    await screenshot(page, testInfo, '01-before-panel-switch');

    // Navigate to Connect panel
    await page.locator('[data-panel="connect"]').click();
    await page.waitForSelector('#panel-connect.active', { timeout: 5000 });
    await page.waitForTimeout(500);

    await screenshot(page, testInfo, '02-connect-panel');

    // Navigate back to Terminal panel
    await page.locator('[data-panel="terminal"]').click();
    await page.waitForSelector('#panel-terminal.active', { timeout: 5000 });
    await page.waitForTimeout(500);

    await screenshot(page, testInfo, '03-after-panel-switch');

    // Measure terminal width after round-trip
    const afterWidth = await page.evaluate(() => {
      const screen = document.querySelector('.xterm-screen');
      return screen ? screen.getBoundingClientRect().width : 0;
    });

    // Width should be within 2% of original (allow for sub-pixel rounding)
    const tolerance = initialWidth * 0.02;
    expect(Math.abs(afterWidth - initialWidth)).toBeLessThanOrEqual(tolerance);
  });

  test('after backgrounding app and resuming, terminal width unchanged', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await setupRealSSHConnection(page, sshServer);
    await ensureKeyboardDismissed(page);
    await page.waitForTimeout(500);

    // Measure initial terminal width
    const initialWidth = await page.evaluate(() => {
      const screen = document.querySelector('.xterm-screen');
      return screen ? screen.getBoundingClientRect().width : 0;
    });
    expect(initialWidth).toBeGreaterThan(0);

    await screenshot(page, testInfo, '01-before-background');

    // Background the app via Home key
    execSync('adb shell input keyevent KEYCODE_HOME');
    // Wait for app to be backgrounded
    await page.waitForTimeout(2000);

    // Resume the app via recent apps
    execSync('adb shell input keyevent KEYCODE_APP_SWITCH');
    await page.waitForTimeout(1000);
    execSync('adb shell input keyevent KEYCODE_APP_SWITCH');
    await page.waitForTimeout(2000);

    await screenshot(page, testInfo, '02-after-resume');

    // Measure terminal width after resume
    const afterWidth = await page.evaluate(() => {
      const screen = document.querySelector('.xterm-screen');
      return screen ? screen.getBoundingClientRect().width : 0;
    });

    // Width should be within 2% of original
    const tolerance = initialWidth * 0.02;
    expect(Math.abs(afterWidth - initialWidth)).toBeLessThanOrEqual(tolerance);
  });
});

test.describe('SessionHandle multi-session sizing (#374)', () => {

  test('two sessions both have correct terminal width', async ({ emulatorPage: page, sshServer }, testInfo) => {
    // Connect first session
    await setupRealSSHConnection(page, sshServer);
    await ensureKeyboardDismissed(page);
    await page.waitForTimeout(500);

    await screenshot(page, testInfo, '01-first-session');

    // Measure first session terminal width
    const firstWidth = await page.evaluate(() => {
      const screen = document.querySelector('.xterm-screen');
      return screen ? screen.getBoundingClientRect().width : 0;
    });
    expect(firstWidth).toBeGreaterThan(0);

    // Connect second session: go to Connect panel, fill form with different profile name
    await page.locator('[data-panel="connect"]').click();
    await page.waitForSelector('#panel-connect.active', { timeout: 5000 });

    // Create a second connection with a different profile name
    await page.evaluate(({ host, port, user, password }) => {
      function setField(id, val) {
        const el = document.getElementById(id);
        if (!el) return;
        const nativeSetter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set;
        if (nativeSetter) nativeSetter.call(el, val);
        else el.value = val;
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      }
      setField('host', host);
      setField('port', String(port));
      setField('remote_a', user);
      setField('remote_c', password);
      // Use a different profile name to create a second session
      const nameEl = document.getElementById('profileName');
      if (nameEl) {
        const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set;
        if (setter) setter.call(nameEl, 'second-session');
        else nameEl.value = 'second-session';
        nameEl.dispatchEvent(new Event('input', { bubbles: true }));
      }
    }, { host: sshServer.host, port: sshServer.port, user: sshServer.user, password: sshServer.password });

    await page.waitForTimeout(300);
    await page.evaluate(() => {
      const form = document.getElementById('connectForm');
      if (form) form.requestSubmit();
    });

    // Wait for the connect button and click it
    await page.waitForSelector('button[data-action="connect"]', { timeout: 5000 });
    await page.waitForTimeout(300);
    await page.evaluate(() => {
      const btns = document.querySelectorAll('button[data-action="connect"]');
      // Click the last connect button (for the new profile)
      const btn = btns[btns.length - 1];
      if (btn) btn.click();
    });

    // Accept host key if prompted
    try {
      const acceptBtn = page.locator('.hostkey-accept');
      await acceptBtn.waitFor({ state: 'visible', timeout: 10000 });
      await page.evaluate(() => {
        const btn = document.querySelector('.hostkey-accept');
        if (btn) btn.click();
      });
      await page.waitForTimeout(1000);
    } catch { /* host key already trusted */ }

    // Wait for second session to be connected
    await page.waitForSelector('.xterm-screen', { timeout: 15000 });
    await ensureKeyboardDismissed(page);
    await page.waitForTimeout(500);

    await screenshot(page, testInfo, '02-second-session');

    // Measure second session terminal width
    const secondWidth = await page.evaluate(() => {
      const screen = document.querySelector('.xterm-screen');
      return screen ? screen.getBoundingClientRect().width : 0;
    });

    const vpWidth = await page.evaluate(() => window.innerWidth);

    // Both sessions should fill > 80% of viewport
    expect(firstWidth / vpWidth).toBeGreaterThan(0.8);
    expect(secondWidth / vpWidth).toBeGreaterThan(0.8);

    // Switch back to first session via session ring/tab and verify width
    // Click the first session tab in the session ring
    const sessionTabs = await page.evaluate(() => {
      const ring = document.getElementById('sessionRing');
      if (!ring) return [];
      return Array.from(ring.querySelectorAll('[data-session-id]')).map(el => el.dataset.sessionId);
    });

    if (sessionTabs.length >= 2) {
      await page.evaluate((id) => {
        const tab = document.querySelector(`[data-session-id="${id}"]`);
        if (tab) tab.click();
      }, sessionTabs[0]);
      await page.waitForTimeout(500);

      await screenshot(page, testInfo, '03-back-to-first');

      const switchedWidth = await page.evaluate(() => {
        const screen = document.querySelector('.xterm-screen');
        return screen ? screen.getBoundingClientRect().width : 0;
      });

      // First session width should be preserved after switch
      const tolerance = firstWidth * 0.02;
      expect(Math.abs(switchedWidth - firstWidth)).toBeLessThanOrEqual(tolerance);
    }
  });
});
