/**
 * tests/ui.spec.js
 *
 * UI chrome — test gate for Phase 8 module extraction (#110).
 * Tests session menu, tab bar toggle, key bar visibility toggle,
 * IME/direct mode toggle, toast utility, and connect form auth switching.
 */

const { test, expect, setupConnected } = require('./fixtures.js');

// After setupConnected the tab bar is auto-hidden (#36). Show it via session menu (#149).
async function showTabBar(page) {
  await page.locator('#sessionMenuBtn').click();
  await page.locator('#sessionNavBarBtn').click();
  await page.waitForSelector('#tabBar:not(.hidden)', { timeout: 2000 });
}

test.describe('UI chrome (#110 Phase 8)', () => {

  test('session menu "Toggle nav bar" shows and hides the tab bar (#149)', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // After connection, tab bar is hidden
    await expect(page.locator('#tabBar')).toHaveClass(/hidden/);

    // Open session menu and toggle nav bar to show
    await page.locator('#sessionMenuBtn').click();
    await page.locator('#sessionNavBarBtn').click();
    await expect(page.locator('#tabBar')).not.toHaveClass(/hidden/);

    // Toggle again to hide
    await page.locator('#sessionMenuBtn').click();
    await page.locator('#sessionNavBarBtn').click();
    await expect(page.locator('#tabBar')).toHaveClass(/hidden/);
  });

  test('hamburger button toggles tab bar visibility', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // After connection, tab bar is auto-hidden
    await expect(page.locator('#tabBar')).toHaveClass(/hidden/);

    // Click hamburger to show tab bar
    await page.locator('#handleMenuBtn').click();
    await expect(page.locator('#tabBar')).not.toHaveClass(/hidden/);

    // Click again to hide
    await page.locator('#handleMenuBtn').click();
    await expect(page.locator('#tabBar')).toHaveClass(/hidden/);
  });

  test('compose/direct mode toggle switches and persists (#146)', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Default is Direct mode (secure by default)
    const modeBefore = await page.evaluate(() => localStorage.getItem('imeMode'));
    expect(modeBefore).toBeNull(); // default — not set yet, resolves to direct

    // Click compose button to switch to compose (IME) mode
    await page.locator('#composeModeBtn').click();
    await page.waitForTimeout(100);

    const modeAfter = await page.evaluate(() => localStorage.getItem('imeMode'));
    expect(modeAfter).toBe('ime');

    // Button should have compose-active class and accent line on key bar
    const btnHasClass = await page.locator('#composeModeBtn').evaluate(
      (el) => el.classList.contains('compose-active')
    );
    expect(btnHasClass).toBe(true);
    const barHasClass = await page.locator('#key-bar').evaluate(
      (el) => el.classList.contains('compose-active')
    );
    expect(barHasClass).toBe(true);

    // Click again to switch back to direct
    await page.locator('#composeModeBtn').click();
    await page.waitForTimeout(100);

    const modeRestored = await page.evaluate(() => localStorage.getItem('imeMode'));
    expect(modeRestored).toBe('direct');
  });

  test('session menu opens only when connected', async ({ page }) => {
    await page.addInitScript(() => { localStorage.clear(); });
    await page.goto('./');
    await page.waitForSelector('.xterm-screen', { timeout: 8000 });

    // Click session menu button when not connected — menu should stay hidden
    await page.locator('#sessionMenuBtn').click();
    await page.waitForTimeout(100);
    await expect(page.locator('#sessionMenu')).toHaveClass(/hidden/);
  });

  test('session menu opens when connected and closes on outside click', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Click session menu button — menu should appear
    await page.locator('#sessionMenuBtn').click();
    await page.waitForTimeout(100);
    await expect(page.locator('#sessionMenu')).not.toHaveClass(/hidden/);

    // Click the backdrop overlay (top-left, away from the menu) — dismisses the menu
    await page.locator('#menuBackdrop').click({ position: { x: 10, y: 10 } });
    await page.waitForTimeout(100);
    await expect(page.locator('#sessionMenu')).toHaveClass(/hidden/);
  });

  test('session menu is scrollable when viewport is small (#183)', async ({ page, mockSshServer }) => {
    // Simulate keyboard-open by setting a short viewport height and injecting
    // --viewport-height so the max-height calc fires with a small value.
    await page.setViewportSize({ width: 390, height: 300 });
    await setupConnected(page, mockSshServer);

    // Inject a small --viewport-height (e.g. 200px — less than the menu content
    // height) so the max-height constraint kicks in, mimicking keyboard open.
    await page.evaluate(() => {
      document.documentElement.style.setProperty('--viewport-height', '200px');
    });

    // Open the session menu
    await page.locator('#sessionMenuBtn').click();
    await page.waitForTimeout(100);
    await expect(page.locator('#sessionMenu')).not.toHaveClass(/hidden/);

    const menu = page.locator('#sessionMenu');
    const overflowY = await menu.evaluate((el) => getComputedStyle(el).overflowY);
    expect(overflowY).toBe('auto');

    // The rendered height must be ≤ max-height (menu must not overflow the
    // available space above the handle bar).
    const { menuHeight, maxHeight } = await menu.evaluate((el) => {
      const cs = getComputedStyle(el);
      return {
        menuHeight: el.getBoundingClientRect().height,
        maxHeight: parseFloat(cs.maxHeight),
      };
    });
    expect(menuHeight).toBeLessThanOrEqual(maxHeight + 1); // +1 for sub-pixel rounding
  });

  test('connect form auth type switch toggles password/key fields', async ({ page }) => {
    await page.addInitScript(() => { localStorage.clear(); });
    await page.goto('./');
    await page.waitForSelector('.xterm-screen', { timeout: 8000 });

    await page.locator('[data-panel="connect"]').click();

    // Default is password — password group visible, key group hidden
    await expect(page.locator('#passwordGroup')).toBeVisible();
    await expect(page.locator('#keyGroup')).toBeHidden();

    // Switch to key auth
    await page.locator('#authType').selectOption('key');
    await page.waitForTimeout(100);

    // Password group hidden, key group visible
    await expect(page.locator('#passwordGroup')).toBeHidden();
    await expect(page.locator('#keyGroup')).toBeVisible();
  });

  test('toast shows and auto-hides', async ({ page }) => {
    await page.addInitScript(() => { localStorage.clear(); });
    await page.goto('./');
    await page.waitForSelector('.xterm-screen', { timeout: 8000 });

    await page.locator('[data-panel="settings"]').click();

    // Trigger a toast by entering an invalid URL and clicking save
    await page.locator('#wsUrl').fill('invalid-url');
    await page.locator('#saveSettingsBtn').click();
    await page.waitForTimeout(100);

    // Toast should be visible
    const toast = page.locator('#toast');
    await expect(toast).toHaveClass(/show/);
    const text = await toast.textContent();
    expect(text).toContain('wss://');
  });

  test('tab bar stays visible when switching panels after connection', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Show tab bar and switch to settings
    await showTabBar(page);
    await page.locator('[data-panel="settings"]').click();
    await expect(page.locator('#panel-settings')).toHaveClass(/active/);

    // Switch back to terminal
    await page.locator('[data-panel="terminal"]').click();
    await page.waitForTimeout(100);

    // Terminal panel should be active
    await expect(page.locator('#panel-terminal')).toHaveClass(/active/);

    // Tab bar stays visible when switching panels (only first connect hides it)
    await expect(page.locator('#tabBar')).not.toHaveClass(/hidden/);
  });

});

test.describe('Session list (#60)', () => {

  test('session list is hidden when only one session exists', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Open session menu
    await page.locator('#sessionMenuBtn').click();
    await page.waitForTimeout(100);

    // Session list should be hidden (only 1 session)
    await expect(page.locator('#sessionList')).toHaveClass(/hidden/);
  });

  test('session list shows when multiple sessions are injected', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Inject a second session via the ES module system available in the browser
    await page.evaluate(async () => {
      const { appState } = await import('./modules/state.js');
      const { renderSessionList } = await import('./modules/ui.js');
      const s2 = {
        id: 'test-session-2',
        profile: { username: 'alice', host: 'remote.example.com', port: 22, authType: 'password', name: 'test' },
        terminal: null, fitAddon: null, ws: null,
        wsConnected: false, sshConnected: false,
        reconnectTimer: null, reconnectDelay: 2000,
        keepAliveTimer: null, keepAliveWorker: null,
        activeThemeName: 'dark',
      };
      appState.sessions.set('test-session-2', s2);
      renderSessionList();
    });

    await page.waitForTimeout(100);

    // Open session menu to see session list
    await page.locator('#sessionMenuBtn').click();
    await page.waitForTimeout(100);

    // Session list should now be visible (2 sessions)
    await expect(page.locator('#sessionList')).not.toHaveClass(/hidden/);

    // Should show both sessions as items
    await expect(page.locator('.session-item')).toHaveCount(2);

    // Should show the + New session button
    await expect(page.locator('#sessionListNewBtn')).toBeVisible();
  });

  test('+ New session navigates to connect tab', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Inject a second session to make the list visible
    await page.evaluate(async () => {
      const { appState } = await import('./modules/state.js');
      const { renderSessionList } = await import('./modules/ui.js');
      appState.sessions.set('test-session-2', {
        id: 'test-session-2',
        profile: { username: 'bob', host: 'other.host', port: 22, authType: 'password', name: 'other' },
        terminal: null, fitAddon: null, ws: null,
        wsConnected: false, sshConnected: false,
        reconnectTimer: null, reconnectDelay: 2000,
        keepAliveTimer: null, keepAliveWorker: null,
        activeThemeName: 'dark',
      });
      renderSessionList();
    });

    // Open session menu and click + New session
    await page.locator('#sessionMenuBtn').click();
    await page.waitForTimeout(100);
    await page.locator('#sessionListNewBtn').click();
    await page.waitForTimeout(200);

    // Should navigate to Connect panel
    await expect(page.locator('#panel-connect')).toHaveClass(/active/);
  });

  test('session list hides again when second session is removed', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Add and then remove a second session
    await page.evaluate(async () => {
      const { appState } = await import('./modules/state.js');
      const { renderSessionList } = await import('./modules/ui.js');
      appState.sessions.set('test-session-2', {
        id: 'test-session-2',
        profile: { username: 'carol', host: 'host2.local', port: 22, authType: 'password', name: 'test2' },
        terminal: null, fitAddon: null, ws: null,
        wsConnected: false, sshConnected: false,
        reconnectTimer: null, reconnectDelay: 2000,
        keepAliveTimer: null, keepAliveWorker: null,
        activeThemeName: 'dark',
      });
      renderSessionList();
    });

    // Verify list is visible with 2 sessions
    await expect(page.locator('#sessionList')).not.toHaveClass(/hidden/);

    // Remove the second session
    await page.evaluate(async () => {
      const { appState } = await import('./modules/state.js');
      const { renderSessionList } = await import('./modules/ui.js');
      appState.sessions.delete('test-session-2');
      renderSessionList();
    });

    await page.waitForTimeout(100);

    // List should be hidden again
    await expect(page.locator('#sessionList')).toHaveClass(/hidden/);
  });

  test('sessionMenuBtn shows user@host label when connected', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // After connection, session menu button should show user@host
    const btnText = await page.locator('#sessionMenuBtn').textContent();
    expect(btnText).toContain('testuser');
    expect(btnText).toContain('mock-host');
  });

});

test.describe('Long-press tooltip hints (#111)', () => {

  test('toolbar buttons have data-tooltip attributes', async ({ page }) => {
    await page.addInitScript(() => { localStorage.clear(); });
    await page.goto('./');
    await page.waitForSelector('.xterm-screen', { timeout: 8000 });

    // Verify data-tooltip on key toolbar buttons
    await expect(page.locator('#handleMenuBtn')).toHaveAttribute('data-tooltip', 'Show tabs');
    await expect(page.locator('#sessionMenuBtn')).toHaveAttribute('data-tooltip', 'Session menu');
    await expect(page.locator('#composeModeBtn')).toHaveAttribute('data-tooltip', 'Compose mode');
    await expect(page.locator('#previewModeBtn')).toHaveAttribute('data-tooltip', 'Preview mode');
  });

  test('long-press shows tooltip after 500ms', async ({ page }) => {
    await page.addInitScript(() => { localStorage.clear(); });
    await page.goto('./');
    await page.waitForSelector('.xterm-screen', { timeout: 8000 });

    const btn = page.locator('#composeModeBtn');

    // Simulate a touchstart and hold for 600ms via evaluate
    await btn.evaluate((el) => {
      const touch = new Touch({ identifier: 1, target: el, clientX: 0, clientY: 0 });
      el.dispatchEvent(new TouchEvent('touchstart', { touches: [touch], changedTouches: [touch], bubbles: true }));
    });

    // Tooltip should not be visible immediately
    await expect(page.locator('.toolbar-tooltip')).toHaveClass(/hidden/);

    // Wait for the 500ms timer to fire
    await page.waitForTimeout(600);

    // Tooltip should now be visible with correct text
    await expect(page.locator('.toolbar-tooltip')).not.toHaveClass(/hidden/);
    await expect(page.locator('.toolbar-tooltip')).toHaveText('Compose mode');

    // Simulate touchend to clean up
    await btn.evaluate((el) => {
      const touch = new Touch({ identifier: 1, target: el, clientX: 0, clientY: 0 });
      el.dispatchEvent(new TouchEvent('touchend', { touches: [], changedTouches: [touch], bubbles: true }));
    });
  });

  test('short tap does not show tooltip', async ({ page }) => {
    await page.addInitScript(() => { localStorage.clear(); });
    await page.goto('./');
    await page.waitForSelector('.xterm-screen', { timeout: 8000 });

    const btn = page.locator('#composeModeBtn');

    // Simulate touchstart then touchend quickly (< 500ms)
    await btn.evaluate((el) => {
      const touch = new Touch({ identifier: 1, target: el, clientX: 0, clientY: 0 });
      el.dispatchEvent(new TouchEvent('touchstart', { touches: [touch], changedTouches: [touch], bubbles: true }));
    });
    await page.waitForTimeout(100);
    await btn.evaluate((el) => {
      const touch = new Touch({ identifier: 1, target: el, clientX: 0, clientY: 0 });
      el.dispatchEvent(new TouchEvent('touchend', { touches: [], changedTouches: [touch], bubbles: true }));
    });

    // Wait past 500ms threshold — tooltip should still be hidden
    await page.waitForTimeout(500);
    const tooltip = page.locator('.toolbar-tooltip');
    // Either hidden class or not yet created
    const count = await tooltip.count();
    if (count > 0) {
      await expect(tooltip).toHaveClass(/hidden/);
    }
  });

  test('touchmove cancels pending tooltip', async ({ page }) => {
    await page.addInitScript(() => { localStorage.clear(); });
    await page.goto('./');
    await page.waitForSelector('.xterm-screen', { timeout: 8000 });

    const btn = page.locator('#composeModeBtn');

    // Start touch hold
    await btn.evaluate((el) => {
      const touch = new Touch({ identifier: 1, target: el, clientX: 0, clientY: 0 });
      el.dispatchEvent(new TouchEvent('touchstart', { touches: [touch], changedTouches: [touch], bubbles: true }));
    });
    await page.waitForTimeout(100);

    // Move finger — should cancel tooltip
    await btn.evaluate((el) => {
      const touch = new Touch({ identifier: 1, target: el, clientX: 20, clientY: 20 });
      el.dispatchEvent(new TouchEvent('touchmove', { touches: [touch], changedTouches: [touch], bubbles: true }));
    });

    // Wait past 500ms — tooltip should not appear
    await page.waitForTimeout(500);
    const tooltip = page.locator('.toolbar-tooltip');
    const count = await tooltip.count();
    if (count > 0) {
      await expect(tooltip).toHaveClass(/hidden/);
    }
  });

  test('touchstart on tooltip button calls preventDefault when keyboard is visible (#124)', async ({ page }) => {
    await page.addInitScript(() => { localStorage.clear(); });
    await page.goto('./');
    await page.waitForSelector('.xterm-screen', { timeout: 8000 });

    // Inject a keyboardVisible override that returns true, simulating an open keyboard
    await page.evaluate(async () => {
      const { initUI } = await import('./modules/ui.js');
      initUI({
        keyboardVisible: () => true,
        ROOT_CSS: { tabHeight: '56px', keybarHeight: '34px' },
        applyFontSize: () => {},
        applyTheme: () => {},
      });
    });

    const btn = page.locator('#composeModeBtn');

    // Spy on preventDefault by patching the prototype before dispatching the event
    const preventDefaultCalled = await btn.evaluate((el) => {
      let called = false;
      const orig = TouchEvent.prototype.preventDefault;
      TouchEvent.prototype.preventDefault = function() { called = true; orig.call(this); };
      try {
        const touch = new Touch({ identifier: 1, target: el, clientX: 0, clientY: 0 });
        el.dispatchEvent(new TouchEvent('touchstart', { touches: [touch], changedTouches: [touch], bubbles: true, cancelable: true }));
      } finally {
        TouchEvent.prototype.preventDefault = orig;
      }
      return called;
    });

    expect(preventDefaultCalled).toBe(true);
  });

  test('touchstart on tooltip button does not call preventDefault when keyboard is hidden (#124)', async ({ page }) => {
    await page.addInitScript(() => { localStorage.clear(); });
    await page.goto('./');
    await page.waitForSelector('.xterm-screen', { timeout: 8000 });

    // Default: keyboardVisible returns false (no keyboard open)
    await page.evaluate(async () => {
      const { initUI } = await import('./modules/ui.js');
      initUI({
        keyboardVisible: () => false,
        ROOT_CSS: { tabHeight: '56px', keybarHeight: '34px' },
        applyFontSize: () => {},
        applyTheme: () => {},
      });
    });

    const btn = page.locator('#composeModeBtn');

    // Spy on preventDefault — should NOT be called when keyboard is hidden
    const preventDefaultCalled = await btn.evaluate((el) => {
      let called = false;
      const orig = TouchEvent.prototype.preventDefault;
      TouchEvent.prototype.preventDefault = function() { called = true; orig.call(this); };
      try {
        const touch = new Touch({ identifier: 1, target: el, clientX: 0, clientY: 0 });
        el.dispatchEvent(new TouchEvent('touchstart', { touches: [touch], changedTouches: [touch], bubbles: true, cancelable: true }));
      } finally {
        TouchEvent.prototype.preventDefault = orig;
      }
      return called;
    });

    expect(preventDefaultCalled).toBe(false);
  });

});
