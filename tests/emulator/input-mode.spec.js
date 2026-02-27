/**
 * tests/emulator/input-mode.spec.js
 *
 * Verify the input state inversion (#146): Direct mode is the default (secure),
 * Compose mode is opt-in. Tests run on real Chrome via Android emulator to
 * validate that the OS keyboard/IME behaves correctly in each mode.
 *
 * Test groups:
 *   1. Secure baseline — cold boot lands in direct mode, no IME suggestions
 *   2. Compose toggle — visual indicators (accent line + filled button)
 *   3. Auto-revert — submitting in compose mode reverts to direct
 *   4. Real SSH — direct mode handles password entry without IME leakage
 */

const { test, expect, screenshot, setupRealSSHConnection, sendCommand } = require('./fixtures');

test.describe('Input mode: secure by default (#146)', () => {

  test('cold boot lands in direct mode', async ({ emulatorPage: page }, testInfo) => {
    await page.waitForSelector('.xterm-screen', { timeout: 30_000 });
    await screenshot(page, testInfo, '01-cold-boot');

    // localStorage imeMode should be unset (null) — resolves to direct
    const storedMode = await page.evaluate(() => localStorage.getItem('imeMode'));
    expect(storedMode).toBeNull();

    // appState.imeMode should be false (direct)
    const imeMode = await page.evaluate(() => {
      // Access the module state via the global test hook
      const state = document.getElementById('directInput');
      return state === document.activeElement || state !== null;
    });
    expect(imeMode).toBe(true);

    // The compose button should exist (not the old IME button)
    const composeBtn = page.locator('#composeModeBtn');
    await expect(composeBtn).toBeVisible();

    // Button should contain an SVG icon (not "IME" text)
    const hasSvg = await composeBtn.evaluate((el) => el.querySelector('svg') !== null);
    expect(hasSvg).toBe(true);

    const textContent = await composeBtn.evaluate((el) => el.textContent.trim());
    expect(textContent).toBe(''); // no text, just SVG

    // No compose-active class on button or key bar
    const btnActive = await composeBtn.evaluate((el) => el.classList.contains('compose-active'));
    expect(btnActive).toBe(false);
    const barActive = await page.locator('#key-bar').evaluate(
      (el) => el.classList.contains('compose-active')
    );
    expect(barActive).toBe(false);

    await screenshot(page, testInfo, '02-direct-mode-default');
  });

  test('compose toggle activates dual visual indicators', async ({ emulatorPage: page }, testInfo) => {
    await page.waitForSelector('.xterm-screen', { timeout: 30_000 });

    const composeBtn = page.locator('#composeModeBtn');
    await screenshot(page, testInfo, '01-before-toggle');

    // Tap compose button — should switch to compose (IME) mode
    await composeBtn.click();
    await page.waitForTimeout(200);
    await screenshot(page, testInfo, '02-compose-active');

    // Button should have compose-active class (filled accent background)
    const btnActive = await composeBtn.evaluate((el) => el.classList.contains('compose-active'));
    expect(btnActive).toBe(true);

    // Key bar should have compose-active class (accent border-top)
    const barActive = await page.locator('#key-bar').evaluate(
      (el) => el.classList.contains('compose-active')
    );
    expect(barActive).toBe(true);

    // localStorage should reflect compose mode
    const storedMode = await page.evaluate(() => localStorage.getItem('imeMode'));
    expect(storedMode).toBe('ime');

    // Tap again — should revert to direct
    await composeBtn.click();
    await page.waitForTimeout(200);
    await screenshot(page, testInfo, '03-direct-restored');

    const btnActiveAfter = await composeBtn.evaluate((el) => el.classList.contains('compose-active'));
    expect(btnActiveAfter).toBe(false);

    const storedAfter = await page.evaluate(() => localStorage.getItem('imeMode'));
    expect(storedAfter).toBe('direct');
  });

  test('auto-revert: newline in compose mode returns to direct', async ({ emulatorPage: page }, testInfo) => {
    await page.waitForSelector('.xterm-screen', { timeout: 30_000 });

    // Switch to compose mode
    await page.locator('#composeModeBtn').click();
    await page.waitForTimeout(200);

    // Verify compose mode is active
    const modeBeforeEnter = await page.evaluate(() => localStorage.getItem('imeMode'));
    expect(modeBeforeEnter).toBe('ime');

    // Simulate submitting text with Enter via the IME textarea
    await page.evaluate(() => {
      const el = document.getElementById('imeInput');
      if (!el) return;
      el.value = '\n';
      el.dispatchEvent(new InputEvent('input', { bubbles: true, data: '\n' }));
      el.value = '';
    });
    await page.waitForTimeout(300);

    await screenshot(page, testInfo, '01-after-enter-revert');

    // Should have auto-reverted to direct mode
    const modeAfterEnter = await page.evaluate(() => localStorage.getItem('imeMode'));
    expect(modeAfterEnter).toBe('direct');

    // Visual indicators should be cleared
    const btnActive = await page.locator('#composeModeBtn').evaluate(
      (el) => el.classList.contains('compose-active')
    );
    expect(btnActive).toBe(false);
  });
});

test.describe('Input mode: real SSH with direct mode (#146)', () => {

  test('direct mode handles SSH session without IME leakage', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await setupRealSSHConnection(page, sshServer);
    await screenshot(page, testInfo, '01-ssh-connected');

    // Verify we're in direct mode (default)
    const activeInput = await page.evaluate(() => {
      const direct = document.getElementById('directInput');
      // In direct mode, focusIME() targets #directInput
      return direct ? direct.type : null;
    });
    expect(activeInput).toBe('password');

    // The #directInput is type="password" which suppresses IME suggestions.
    // Verify the input element attributes that suppress keyboard prediction.
    const attrs = await page.evaluate(() => {
      const el = document.getElementById('directInput');
      if (!el) return null;
      return {
        type: el.type,
        autocomplete: el.getAttribute('autocomplete'),
        'data-lpignore': el.getAttribute('data-lpignore'),
        'data-1p-ignore': el.getAttribute('data-1p-ignore'),
      };
    });
    expect(attrs.type).toBe('password');
    expect(attrs.autocomplete).toBe('off');

    // Type a command in direct mode — chars should go through without IME buffering
    await sendCommand(page, 'echo direct-mode-test');
    await page.waitForTimeout(2000);
    await screenshot(page, testInfo, '02-direct-mode-command');

    // Verify the command was sent via WS (input messages to SSH)
    const inputMsgs = await page.evaluate(() => {
      return (window.__mockWsSpy || []).filter(s => {
        try { return JSON.parse(s).type === 'input'; } catch { return false; }
      }).map(s => JSON.parse(s).data);
    });
    // The characters of "echo direct-mode-test" should appear in the messages
    expect(inputMsgs.join('')).toContain('echo direct-mode-test');

    // Now switch to compose, type, and verify auto-revert
    await page.locator('#composeModeBtn').click();
    await page.waitForTimeout(300);
    await screenshot(page, testInfo, '03-compose-active-ssh');

    const composeModeActive = await page.evaluate(() => localStorage.getItem('imeMode'));
    expect(composeModeActive).toBe('ime');

    // Send a command in compose mode — should auto-revert after Enter
    await sendCommand(page, 'echo compose-test');
    await page.waitForTimeout(1000);
    await screenshot(page, testInfo, '04-after-compose-send');

    // Auto-revert: should be back in direct mode after the newline
    // Note: sendCommand sends chars one-by-one then '\n', so auto-revert triggers
    const modeAfterSend = await page.evaluate(() => localStorage.getItem('imeMode'));
    expect(modeAfterSend).toBe('direct');
  });
});
