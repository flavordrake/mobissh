/**
 * tests/emulator/explore-workflow.spec.js
 *
 * Exploratory interaction: clear data → connect SSH → scroll in terminal.
 * No assertions — captures screenshots and video for human review.
 */

const { test, expect, screenshot, setupRealSSHConnection, sendCommand, swipe, pinch, COMPOSE_INPUT_ID, DIRECT_INPUT_ID } = require('./fixtures');

test.describe('Workflow exploration — clear, login, interact', () => {

  test('clear → SSH login → generate scrollback → vertical swipe', async ({ emulatorPage: page, sshServer }, testInfo) => {
    // 1. Fresh state — emulatorPage fixture already cleared localStorage + reloaded
    await page.waitForSelector('.xterm-screen', { timeout: 30_000 });
    await screenshot(page, testInfo, '01-fresh-start');

    // 2. Connect to real SSH server
    await setupRealSSHConnection(page, sshServer);
    await screenshot(page, testInfo, '02-connected');

    // 3. Generate scrollback content — enough to scroll
    await sendCommand(page, 'seq 1 100');
    await page.waitForTimeout(2000);
    await screenshot(page, testInfo, '03-scrollback-generated');

    // 4. Swipe up (scroll back through output)
    const termRect = await page.evaluate(() => {
      const el = document.querySelector('.xterm-screen');
      if (!el) return null;
      const r = el.getBoundingClientRect();
      return { width: r.width, height: r.height };
    });

    if (termRect) {
      const cx = termRect.width / 2;
      // Swipe from bottom-third to top-third
      await swipe(page, '.xterm-screen', cx, termRect.height * 0.7, cx, termRect.height * 0.3, 15);
      await page.waitForTimeout(500);
      await screenshot(page, testInfo, '04-after-swipe-up');

      // Second swipe
      await swipe(page, '.xterm-screen', cx, termRect.height * 0.7, cx, termRect.height * 0.3, 15);
      await page.waitForTimeout(500);
      await screenshot(page, testInfo, '05-after-second-swipe');
    }

    // 5. Capture terminal state
    const viewportY = await page.evaluate(() => {
      const t = window.__testTerminal || (window.appState && window.appState.terminal);
      return t ? t.buffer.active.viewportY : 'no terminal ref';
    });
    const baseY = await page.evaluate(() => {
      const t = window.__testTerminal || (window.appState && window.appState.terminal);
      return t ? t.buffer.active.baseY : 'no terminal ref';
    });

    // Attach state as text for review
    await testInfo.attach('terminal-scroll-state', {
      body: Buffer.from(`viewportY: ${viewportY}\nbaseY: ${baseY}\n`),
      contentType: 'text/plain',
    });
  });

  test('clear → SSH login → horizontal swipe (tmux window switch)', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await page.waitForSelector('.xterm-screen', { timeout: 30_000 });
    await setupRealSSHConnection(page, sshServer);
    await screenshot(page, testInfo, '01-connected');

    // Start tmux
    await sendCommand(page, 'tmux');
    await page.waitForTimeout(2000);
    await screenshot(page, testInfo, '02-tmux-started');

    // Create a second window
    await sendCommand(page, ''); // clear any prompt
    await page.evaluate(() => {
      // Send tmux prefix + c (new window) directly via WS
      const ws = document.querySelector('#terminal')?.__ws || window.__testWs;
      // Fallback: type the key sequence through IME
    });
    // Use the IME to send Ctrl-B then c
    const ids = [COMPOSE_INPUT_ID, DIRECT_INPUT_ID];
    await page.evaluate((ids) => {
      for (const id of ids) { const el = document.getElementById(id); if (el) {
        el.value = '\x02';
        el.dispatchEvent(new InputEvent('input', { bubbles: true, data: '\x02' }));
        el.value = ''; return;
      } }
    }, ids);
    await page.waitForTimeout(200);
    await page.evaluate((ids) => {
      for (const id of ids) { const el = document.getElementById(id); if (el) {
        el.value = 'c';
        el.dispatchEvent(new InputEvent('input', { bubbles: true, data: 'c' }));
        el.value = ''; return;
      } }
    }, ids);
    await page.waitForTimeout(1000);
    await screenshot(page, testInfo, '03-tmux-second-window');

    // Swipe left (should send tmux prev window: Ctrl-B p)
    const termRect = await page.evaluate(() => {
      const el = document.querySelector('.xterm-screen');
      if (!el) return null;
      const r = el.getBoundingClientRect();
      return { width: r.width, height: r.height };
    });

    if (termRect) {
      const cy = termRect.height / 2;
      await swipe(page, '.xterm-screen', termRect.width * 0.8, cy, termRect.width * 0.2, cy, 15);
      await page.waitForTimeout(1000);
      await screenshot(page, testInfo, '04-after-swipe-left');

      // Swipe right (should send tmux next window: Ctrl-B n)
      await swipe(page, '.xterm-screen', termRect.width * 0.2, cy, termRect.width * 0.8, cy, 15);
      await page.waitForTimeout(1000);
      await screenshot(page, testInfo, '05-after-swipe-right');
    }

    // Capture WS spy for tmux commands
    const wsMsgs = await page.evaluate(() => window.__mockWsSpy || []);
    await testInfo.attach('ws-messages', {
      body: Buffer.from(wsMsgs.join('\n')),
      contentType: 'text/plain',
    });
  });

  test('clear → settings → pinch zoom → verify layout intact', async ({ emulatorPage: page }, testInfo) => {
    await page.waitForSelector('.xterm-screen', { timeout: 30_000 });
    await screenshot(page, testInfo, '01-terminal-loaded');

    // Navigate to settings
    await page.locator('[data-panel="settings"]').click();
    await page.waitForSelector('#panel-settings.active', { timeout: 5000 });
    await screenshot(page, testInfo, '02-settings-panel');

    // Capture layout metrics before pinch
    const beforeMetrics = await page.evaluate(() => {
      const app = document.getElementById('app');
      const tabBar = document.getElementById('tabBar');
      const vv = window.visualViewport;
      return {
        appHeight: app?.offsetHeight,
        tabBarHeight: tabBar?.offsetHeight,
        tabBarTop: tabBar?.getBoundingClientRect().top,
        viewportHeight: vv?.height,
        viewportScale: vv?.scale,
      };
    });

    // Pinch out (zoom in)
    await pinch(page, '#panel-settings', 100, 300, 15);
    await page.waitForTimeout(1000);
    await screenshot(page, testInfo, '03-after-pinch-zoom-in');

    // Capture layout metrics after pinch
    const afterMetrics = await page.evaluate(() => {
      const app = document.getElementById('app');
      const tabBar = document.getElementById('tabBar');
      const vv = window.visualViewport;
      return {
        appHeight: app?.offsetHeight,
        tabBarHeight: tabBar?.offsetHeight,
        tabBarTop: tabBar?.getBoundingClientRect().top,
        viewportHeight: vv?.height,
        viewportScale: vv?.scale,
      };
    });

    await testInfo.attach('layout-metrics', {
      body: Buffer.from(`Before pinch:\n${JSON.stringify(beforeMetrics, null, 2)}\n\nAfter pinch:\n${JSON.stringify(afterMetrics, null, 2)}\n`),
      contentType: 'text/plain',
    });

    // Navigate back to terminal
    await page.locator('[data-panel="terminal"]').click();
    await page.waitForTimeout(500);
    await screenshot(page, testInfo, '04-back-to-terminal');
  });
});
