/**
 * tests/visual-smoke.spec.js
 *
 * Headless Playwright smoke tests for catastrophic usability regressions.
 * These are fast exit-gate tests that block merges when fundamental UI
 * contracts are broken (terminal not visible, lobby covering session,
 * output not routing, input not wired).
 */

const { test, expect, setupConnected, activeInputSelector } = require('./fixtures.js');

test.describe('Visual smoke tests', { tag: '@smoke' }, () => {

  test('terminal fills viewport after connect', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // The active session container (not lobby) should fill most of the viewport
    const viewportHeight = page.viewportSize().height;
    const containerHeight = await page.evaluate(() => {
      const containers = document.querySelectorAll('#terminal > [data-session-id]');
      for (const el of containers) {
        if (!el.classList.contains('hidden')) {
          return el.getBoundingClientRect().height;
        }
      }
      return 0;
    });

    // Terminal container must be > 50% of viewport height
    expect(containerHeight).toBeGreaterThan(viewportHeight * 0.5);
  });

  test('terminal receives output after connect', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // The mock server sends "MobiSSH mock server ready" on connect.
    // Verify the terminal buffer contains that output.
    const hasOutput = await page.evaluate(() => {
      const containers = document.querySelectorAll('#terminal > [data-session-id]');
      for (const el of containers) {
        if (!el.classList.contains('hidden')) {
          return el.textContent.includes('mock server ready');
        }
      }
      return false;
    });

    expect(hasOutput).toBe(true);
  });

  test('lobby hidden after connect', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // The lobby container should have the hidden class after connecting
    const lobbyHidden = await page.evaluate(() => {
      const lobby = document.querySelector('#terminal > [data-session-id="lobby"]');
      if (!lobby) return true; // no lobby element is also acceptable
      return lobby.classList.contains('hidden');
    });

    expect(lobbyHidden).toBe(true);
  });

  test('session menu shows connected host', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    const menuText = await page.locator('#sessionMenuBtn').textContent();
    expect(menuText).toContain('mock-host');
  });

  test('terminal responsive to input after connect', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Clear WS spy to isolate our input
    await page.evaluate(() => { window.__mockWsSpy = []; });

    // Send input via the active input element
    const inputId = await activeInputSelector(page);
    await page.locator(`#${inputId}`).focus();
    await page.keyboard.type('ls');
    await page.waitForTimeout(300);

    // Verify at least one input message was sent via WebSocket
    const inputMessages = await page.evaluate(() =>
      (window.__mockWsSpy || []).filter(s => {
        try { return JSON.parse(s).type === 'input'; } catch (_) { return false; }
      })
    );

    expect(inputMessages.length).toBeGreaterThan(0);
  });

  test('welcome banner visible before connect', async ({ page }) => {
    await page.addInitScript(() => { localStorage.clear(); });
    await page.goto('./');
    await page.waitForSelector('.xterm-screen', { timeout: 8000 });

    // The lobby terminal should show "MobiSSH" welcome text
    const hasBanner = await page.evaluate(() => {
      const terminal = document.querySelector('#terminal');
      return terminal ? terminal.textContent.includes('MobiSSH') : false;
    });

    expect(hasBanner).toBe(true);
  });

});
