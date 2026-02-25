/**
 * tests/ime.spec.js
 *
 * IME composition + key routing integration tests.
 *
 * These tests verify the core IME→SSH input pipeline (the bugs in #23, #24,
 * #32, #37 all live in this path). They use the mockSshServer fixture which
 * spins up a real WebSocket server in the test process. The page is pointed
 * at it via localStorage, a profile is pre-seeded, and the mock server
 * auto-responds with `{type:"connected"}` so sshConnected becomes true.
 *
 * What is tested:
 *   - compositionend text is sent to the SSH stream (GBoard swipe commit)
 *   - compositionstart suppresses premature input events while composing
 *   - Ctrl+C sends \x03 (interrupt)
 *   - Ctrl+Z sends \x1a (suspend)
 *   - Enter via compositionend sends \r (not \n)
 *   - key bar Esc button sends \x1b
 *   - key bar Up/Down arrows send correct VT sequences
 *
 * What is NOT tested here (requires real GBoard on a physical device):
 *   - Exact GBoard timing (compositionupdate rate, word candidate cycling)
 *   - Real IME candidate disambiguation
 */

const { test, expect } = require('./fixtures.js');

// ── helpers ───────────────────────────────────────────────────────────────────

/** Dispatch a full GBoard-style composition cycle on #imeInput. */
async function imeCompose(page, text) {
  await page.evaluate((t) => {
    const el = document.getElementById('imeInput');
    el.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
    for (let i = 1; i <= t.length; i++) {
      el.dispatchEvent(new CompositionEvent('compositionupdate', {
        bubbles: true, data: t.slice(0, i),
      }));
    }
    el.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: t }));
    el.value = t;
    el.dispatchEvent(new InputEvent('input', {
      bubbles: true, data: t, inputType: 'insertCompositionText',
    }));
    el.value = '';
  }, text);
}

/** Get all `input` type SSH messages sent from the page to the mock server. */
async function getInputMessages(page) {
  // Wait a tick for event handlers to process
  await page.waitForTimeout(100);
  const raw = await page.evaluate(() => window.__mockWsSpy || []);
  return raw
    .map((s) => { try { return JSON.parse(s); } catch (_) { return null; } })
    .filter((m) => m && m.type === 'input');
}

// ── setup: connect to mock server ────────────────────────────────────────────

/**
 * Navigate to the app, fill the connect form with mock-server credentials,
 * submit, wait for the mock SSH server to respond with `connected`, then
 * return to the terminal tab with the IME textarea focused.
 *
 * No profiles are pre-seeded — we use the form directly so there's no vault
 * involvement and no UI state ambiguity.
 */
async function setupConnected(page, mockSshServer) {
  // Inject WS spy before any app code runs — wraps window.WebSocket.send
  await page.addInitScript(() => {
    window.__mockWsSpy = [];
    const OrigWS = window.WebSocket;
    window.WebSocket = class extends OrigWS {
      send(data) {
        window.__mockWsSpy.push(data);
        super.send(data);
      }
    };
  });

  // Clear localStorage (no profiles → app lands on Terminal tab)
  await page.addInitScript(() => { localStorage.clear(); });

  await page.goto('./');
  await page.waitForSelector('.xterm-screen', { timeout: 8000 });

  // Pre-create a test vault so saveProfile() doesn't show the setup modal
  await page.evaluate(async () => {
    const { createVault } = await import('./modules/vault.js');
    await createVault('test', false);
  });

  // Set WS URL to the mock server BEFORE connecting
  await page.evaluate((port) => {
    localStorage.setItem('wsUrl', `ws://localhost:${port}`);
  }, mockSshServer.port);

  // Navigate to Connect tab and fill the form
  await page.locator('[data-panel="connect"]').click();
  await page.locator('#host').fill('mock-host');
  await page.locator('#port').fill('22');
  await page.locator('#username').fill('testuser');
  await page.locator('#password').fill('testpass');

  // Submit — calls saveProfile() then connect()
  await page.locator('#connectForm button[type="submit"]').click();

  // Wait until the app sends a `resize` message — this is the first message sent
  // after the app receives `{type: "connected"}` from the mock server.
  await page.waitForFunction(() => {
    return (window.__mockWsSpy || []).some((s) => {
      try { return JSON.parse(s).type === 'resize'; } catch (_) { return false; }
    });
  }, null, { timeout: 10_000 });

  // The app calls switchToTerminal() on form submit, then on receiving `connected`
  // it calls focusIME() automatically and hides the tab bar (#36).
  // Wait for the terminal panel to be active, then ensure IME textarea is focused.
  await page.waitForSelector('#panel-terminal.active', { timeout: 5000 });
  await page.locator('#imeInput').focus().catch(() => {});
  await page.waitForTimeout(100); // let IME focus settle
}

// ── tests ─────────────────────────────────────────────────────────────────────

test.describe('IME composition → SSH input routing', () => {
  test('compositionend text is forwarded to SSH stream', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Clear spy before the actual test action
    await page.evaluate(() => { window.__mockWsSpy = []; });

    await imeCompose(page, 'ls');

    const msgs = await getInputMessages(page);
    expect(msgs.some((m) => m.data === 'ls')).toBe(true);
  });

  test('Enter via compositionend sends \\r (not \\n)', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    await imeCompose(page, '\n'); // GBoard sends newline

    const msgs = await getInputMessages(page);
    expect(msgs.some((m) => m.data === '\r')).toBe(true);
    expect(msgs.every((m) => m.data !== '\n')).toBe(true);
  });

  test('compositionstart suppresses premature input while composing', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    // Fire compositionstart + mid-composition input but do NOT fire compositionend
    await page.evaluate(() => {
      const el = document.getElementById('imeInput');
      el.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
      el.dispatchEvent(new CompositionEvent('compositionupdate', { bubbles: true, data: 'l' }));
      el.value = 'l';
      // This input event should be swallowed because isComposing is true
      el.dispatchEvent(new InputEvent('input', {
        bubbles: true, data: 'l', isComposing: true,
      }));
    });

    const msgs = await getInputMessages(page);
    // No input should have been sent during active composition
    expect(msgs).toHaveLength(0);
  });

  test('Ctrl+letter via compositionend sends control character', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    // Activate sticky Ctrl modifier, then compose 'c' → should produce \x03
    await page.locator('#keyCtrl').click();
    await imeCompose(page, 'c');

    const msgs = await getInputMessages(page);
    expect(msgs.some((m) => m.data === '\x03')).toBe(true); // ^C
  });

  test('Ctrl+Z via compositionend sends \\x1a (suspend)', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    await page.locator('#keyCtrl').click();
    await imeCompose(page, 'z');

    const msgs = await getInputMessages(page);
    expect(msgs.some((m) => m.data === '\x1a')).toBe(true); // ^Z
  });

  test('IME preview shows composition text, hides on commit', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    const preview = page.locator('#imePreview');

    // Fire compositionstart + compositionupdate — preview should appear
    await page.evaluate(() => {
      const el = document.getElementById('imeInput');
      el.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
      el.dispatchEvent(new CompositionEvent('compositionupdate', { bubbles: true, data: 'hello' }));
    });
    await expect(preview).not.toHaveClass(/hidden/);
    await expect(preview).toHaveText('hello');

    // Fire compositionend — preview should hide
    await page.evaluate(() => {
      const el = document.getElementById('imeInput');
      el.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: 'hello' }));
    });
    await expect(preview).toHaveClass(/hidden/);
  });
});

test.describe('Issue #85 — compositioncancel resets IME state', () => {
  test('compositioncancel clears isComposing so subsequent input is not dropped', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    // Start composition, then cancel (simulates voice recognition abort)
    await page.evaluate(() => {
      const el = document.getElementById('imeInput');
      el.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
      el.dispatchEvent(new CompositionEvent('compositionupdate', { bubbles: true, data: 'partial' }));
      // Cancel — should reset isComposing
      el.dispatchEvent(new Event('compositioncancel', { bubbles: true }));
    });

    // Now send a normal composition — it should NOT be suppressed
    await imeCompose(page, 'hello');

    const msgs = await getInputMessages(page);
    expect(msgs.some((m) => m.data === 'hello')).toBe(true);
  });

  test('compositionend prefers ime.value over e.data', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    // Simulate: e.data is empty (voice dictation quirk) but textarea has the full text
    await page.evaluate(() => {
      const el = document.getElementById('imeInput');
      el.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
      el.value = 'full phrase';
      el.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: '' }));
      el.dispatchEvent(new InputEvent('input', {
        bubbles: true, data: 'full phrase', inputType: 'insertCompositionText',
      }));
      el.value = '';
    });

    const msgs = await getInputMessages(page);
    expect(msgs.some((m) => m.data === 'full phrase')).toBe(true);
  });
});

test.describe('Key bar buttons → SSH input', () => {
  test('Esc button sends \\x1b', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    await page.locator('#keyEsc').click();

    const msgs = await getInputMessages(page);
    expect(msgs.some((m) => m.data === '\x1b')).toBe(true);
  });

  test('Up arrow button sends \\x1b[A', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    await page.locator('#keyUp').click();

    const msgs = await getInputMessages(page);
    expect(msgs.some((m) => m.data === '\x1b[A')).toBe(true);
  });

  test('Down arrow button sends \\x1b[B', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    await page.locator('#keyDown').click();

    const msgs = await getInputMessages(page);
    expect(msgs.some((m) => m.data === '\x1b[B')).toBe(true);
  });

  test('Tab button sends \\t', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    await page.locator('#keyTab').click();

    const msgs = await getInputMessages(page);
    expect(msgs.some((m) => m.data === '\t')).toBe(true);
  });

  test('key repeat: holding Up arrow sends multiple \\x1b[A (#89)', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    // Simulate a long-press via pointerdown, wait for repeat, then pointerup
    const keyUp = page.locator('#keyUp');
    await keyUp.dispatchEvent('pointerdown', { bubbles: true });
    // Wait 600ms — should get: immediate fire + at least one repeat (400ms delay + 80ms interval)
    await page.waitForTimeout(600);
    await keyUp.dispatchEvent('pointerup', { bubbles: true });

    const msgs = await getInputMessages(page);
    const upArrows = msgs.filter((m) => m.data === '\x1b[A');
    expect(upArrows.length).toBeGreaterThanOrEqual(2);
  });

  test('screenshot: terminal in connected state with key bar', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await page.screenshot({ path: 'test-results/screenshots/terminal-connected.png' });
  });
});
