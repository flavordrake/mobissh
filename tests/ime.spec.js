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

const path = require('path');
const { test, expect } = require('./fixtures.js');

// ── helpers ───────────────────────────────────────────────────────────────────

/** Dispatch a full GBoard-style composition cycle on #imeInput. */
async function imeCompose(page, text) {
  await page.evaluate((t) => {
    const el = document.getElementById('imeInput');
    el.focus();
    el.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
    for (let i = 1; i <= t.length; i++) {
      const partial = t.slice(0, i);
      el.value = partial;
      el.dispatchEvent(new InputEvent('beforeinput', {
        bubbles: true, inputType: 'insertCompositionText', data: partial,
      }));
      el.dispatchEvent(new InputEvent('input', {
        bubbles: true, inputType: 'insertCompositionText', data: partial,
      }));
      el.dispatchEvent(new CompositionEvent('compositionupdate', {
        bubbles: true, data: partial,
      }));
    }
    el.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: t }));
    el.dispatchEvent(new InputEvent('beforeinput', {
      bubbles: true, inputType: 'insertCompositionText', data: t,
    }));
    el.dispatchEvent(new InputEvent('input', {
      bubbles: true, inputType: 'insertCompositionText', data: t,
    }));
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
  await page.locator('#remote_a').fill('testuser');
  await page.locator('#remote_c').fill('testpass');

  // Submit — saves profile (no longer connects)
  await page.locator('#connectForm button[type="submit"]').click();

  // Connect via the profile's Connect button (wait for vault encrypt + profile render)
  const connectBtn = page.locator('[data-action="connect"]').first();
  await connectBtn.waitFor({ state: 'visible', timeout: 5000 });
  await connectBtn.click();

  // Wait until the app sends a `resize` message — this is the first message sent
  // after the app receives `{type: "connected"}` from the mock server.
  await page.waitForFunction(() => {
    return (window.__mockWsSpy || []).some((s) => {
      try { return JSON.parse(s).type === 'resize'; } catch (_) { return false; }
    });
  }, null, { timeout: 10_000 });

  // connectFromProfile() navigates to terminal on success, then on receiving
  // `connected` it calls focusIME() automatically and hides the tab bar (#36).
  // Wait for the terminal panel to be active, then ensure IME textarea is focused.
  await page.waitForSelector('#panel-terminal.active', { timeout: 5000 });
  await page.locator('#imeInput').focus().catch(() => {});
  await page.waitForTimeout(100); // let IME focus settle
}

// ── tests ─────────────────────────────────────────────────────────────────────

test.describe('IME composition → SSH input routing', { tag: '@device-critical' }, () => {
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

  test('IME action buttons show on composition, hide on commit', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    const actions = page.locator('#imeActions');

    // Fire compositionstart + compositionupdate — action bar should appear
    await page.evaluate(() => {
      const el = document.getElementById('imeInput');
      el.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
      el.dispatchEvent(new CompositionEvent('compositionupdate', { bubbles: true, data: 'hello' }));
    });
    await expect(actions).not.toHaveClass(/hidden/);

    // Fire compositionend — action bar hides after deferred idle (1.5s)
    await page.evaluate(() => {
      const el = document.getElementById('imeInput');
      el.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: 'hello' }));
    });
    await expect(actions).toHaveClass(/hidden/, { timeout: 3000 });
  });
});

test.describe('Issue #74 — compose action buttons Clear and Send', { tag: '@device-critical' }, () => {
  test('Clear button hides actions and clears textarea without sending', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    // Start composition to show action bar
    await page.evaluate(() => {
      const el = document.getElementById('imeInput');
      el.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
      el.dispatchEvent(new CompositionEvent('compositionupdate', { bubbles: true, data: 'hello' }));
    });

    const actions = page.locator('#imeActions');
    await expect(actions).not.toHaveClass(/hidden/);

    // Click Clear button
    await page.locator('#imeClearBtn').click();

    // Actions should be hidden and no input sent
    await expect(actions).toHaveClass(/hidden/);
    const msgs = await getInputMessages(page);
    expect(msgs).toHaveLength(0);
  });

  test('Send button commits textarea text and hides actions', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    // Start composition to show action bar, set textarea value
    await page.evaluate(() => {
      const el = document.getElementById('imeInput');
      el.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
      el.dispatchEvent(new CompositionEvent('compositionupdate', { bubbles: true, data: 'hello' }));
      el.value = 'hello';
    });

    const actions = page.locator('#imeActions');
    await expect(actions).not.toHaveClass(/hidden/);

    // Click Send button — commits text without adding \r
    await page.locator('#imeCommitBtn').click();

    // Actions should be hidden and text sent to SSH (no \r)
    await expect(actions).toHaveClass(/hidden/);
    const msgs = await getInputMessages(page);
    expect(msgs.some((m) => m.data === 'hello')).toBe(true);
    expect(msgs.every((m) => m.data !== '\r')).toBe(true);
  });

  test('action buttons remain visible alongside textarea during composition', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    await page.evaluate(() => {
      const el = document.getElementById('imeInput');
      el.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
      el.dispatchEvent(new CompositionEvent('compositionupdate', { bubbles: true, data: 'typed' }));
    });

    // Buttons should be visible
    await expect(page.locator('#imeClearBtn')).toBeVisible();
    await expect(page.locator('#imeCommitBtn')).toBeVisible();
  });
});

test.describe('Issue #85 — compositioncancel resets IME state', { tag: '@device-critical' }, () => {
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

test.describe('Key bar buttons → SSH input', { tag: '@headless-adequate' }, () => {
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

// ── IME state machine — compose + preview mode (#106) ─────────────────────

/** Enable compose mode + preview mode, return to terminal with IME focused. */
async function enableComposePreview(page) {
  // Enable compose mode
  await page.evaluate(() => {
    const btn = document.getElementById('composeModeBtn');
    if (btn) btn.click();
  });
  await page.waitForTimeout(100);
  // Enable preview mode (eye toggle — only visible when compose is on)
  await page.evaluate(() => {
    const btn = document.getElementById('previewModeBtn');
    if (btn) btn.click();
  });
  await page.waitForTimeout(100);
}

/** Simulate a GBoard swipe composition on #imeInput. */
async function swipeCompose(page, text) {
  await page.evaluate((t) => {
    const el = document.getElementById('imeInput');
    el.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
    for (let i = 1; i <= t.length; i++) {
      el.dispatchEvent(new CompositionEvent('compositionupdate', { bubbles: true, data: t.slice(0, i) }));
    }
    el.value = (el.value ? el.value + ' ' : '') + t;
    el.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: t }));
  }, text);
  await page.waitForTimeout(100);
}

const SM_DIR = path.join(__dirname, '..', 'test-results', 'screenshots', 'state-machine');

test.describe('IME state machine — compose + preview (#106)', { tag: '@device-critical' }, () => {

  test('preview mode holds text — nothing sent until commit', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableComposePreview(page);
    await page.screenshot({ path: path.join(SM_DIR, '01-compose-preview-enabled.png') });
    await page.evaluate(() => { window.__mockWsSpy = []; });

    await swipeCompose(page, 'hello');
    await page.screenshot({ path: path.join(SM_DIR, '02-previewing-hello.png') });

    // Text should be in textarea but NOT sent to SSH
    const imeVal = await page.evaluate(() => document.getElementById('imeInput').value);
    expect(imeVal).toContain('hello');
    const msgs = await getInputMessages(page);
    expect(msgs).toHaveLength(0);

    // Action buttons should be visible
    const actions = page.locator('#imeActions');
    await expect(actions).not.toHaveClass(/hidden/);
  });

  test('commit button sends held text without Enter', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableComposePreview(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    await swipeCompose(page, 'world');
    await page.screenshot({ path: path.join(SM_DIR, '03-before-commit.png') });
    await page.locator('#imeCommitBtn').click();
    await page.waitForTimeout(100);
    await page.screenshot({ path: path.join(SM_DIR, '04-after-commit.png') });

    const msgs = await getInputMessages(page);
    expect(msgs.some((m) => m.data.includes('world'))).toBe(true);
    expect(msgs.every((m) => m.data !== '\r')).toBe(true);
    await expect(page.locator('#imeActions')).toHaveClass(/hidden/);
  });

  test('Enter key in preview sends text + \\r', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableComposePreview(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    await swipeCompose(page, 'command');
    await page.screenshot({ path: path.join(SM_DIR, '05-before-enter.png') });
    await page.locator('#imeInput').press('Enter');
    await page.waitForTimeout(100);
    await page.screenshot({ path: path.join(SM_DIR, '06-after-enter.png') });

    const msgs = await getInputMessages(page);
    expect(msgs.some((m) => m.data.includes('command'))).toBe(true);
    expect(msgs.some((m) => m.data === '\r')).toBe(true);
  });

  test('clear button discards text without sending', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableComposePreview(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    await swipeCompose(page, 'discard');
    await page.screenshot({ path: path.join(SM_DIR, '07-before-clear.png') });
    await page.locator('#imeClearBtn').click();
    await page.waitForTimeout(100);
    await page.screenshot({ path: path.join(SM_DIR, '08-after-clear.png') });

    const msgs = await getInputMessages(page);
    expect(msgs).toHaveLength(0);
    await expect(page.locator('#imeActions')).toHaveClass(/hidden/);
    const imeVal = await page.evaluate(() => document.getElementById('imeInput').value);
    expect(imeVal).toBe('');
  });

  test('multiple swipe words accumulate in preview', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableComposePreview(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    await swipeCompose(page, 'hello');
    await page.screenshot({ path: path.join(SM_DIR, '09-first-word.png') });
    await swipeCompose(page, 'world');
    await page.screenshot({ path: path.join(SM_DIR, '10-second-word.png') });

    const imeVal = await page.evaluate(() => document.getElementById('imeInput').value);
    expect(imeVal).toContain('hello');
    expect(imeVal).toContain('world');
    const msgs = await getInputMessages(page);
    expect(msgs).toHaveLength(0);
  });

  test('eye toggle only controls visibility — text preserved, no commit', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableComposePreview(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    await swipeCompose(page, 'peek-a-boo');
    await page.screenshot({ path: path.join(SM_DIR, '11-before-eye-off.png') });
    await expect(page.locator('#imeInput')).toHaveClass(/ime-visible/);

    // Toggle eye off — hides textarea, does NOT commit or discard
    await page.evaluate(() => {
      const btn = document.getElementById('previewModeBtn');
      if (btn) btn.click();
    });
    await page.waitForTimeout(100);
    await page.screenshot({ path: path.join(SM_DIR, '12-after-eye-off.png') });

    // Nothing sent to SSH
    const msgs = await getInputMessages(page);
    expect(msgs).toHaveLength(0);
    // Textarea hidden
    await expect(page.locator('#imeInput')).not.toHaveClass(/ime-visible/);
    await expect(page.locator('#imeActions')).toHaveClass(/hidden/);
    // Text still in textarea (preserved, just hidden)
    const imeVal = await page.evaluate(() => document.getElementById('imeInput').value);
    expect(imeVal).toContain('peek-a-boo');

    // Toggle eye back on — textarea reappears with same text
    await page.evaluate(() => {
      const btn = document.getElementById('previewModeBtn');
      if (btn) btn.click();
    });
    await page.waitForTimeout(100);
    await page.screenshot({ path: path.join(SM_DIR, '12b-after-eye-on.png') });
    await expect(page.locator('#imeInput')).toHaveClass(/ime-visible/);
    const imeVal2 = await page.evaluate(() => document.getElementById('imeInput').value);
    expect(imeVal2).toContain('peek-a-boo');
  });

  test('toggling compose off commits held preview and hides eye', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableComposePreview(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    await swipeCompose(page, 'bye');
    await page.screenshot({ path: path.join(SM_DIR, '13-before-compose-off.png') });

    await page.evaluate(() => {
      const btn = document.getElementById('composeModeBtn');
      if (btn) btn.click();
    });
    await page.waitForTimeout(100);
    await page.screenshot({ path: path.join(SM_DIR, '14-after-compose-off.png') });

    const msgs = await getInputMessages(page);
    expect(msgs.some((m) => m.data.includes('bye'))).toBe(true);
    await expect(page.locator('#previewModeBtn')).toHaveClass(/hidden/);
  });

  test('editing state: tap into textarea prevents auto-clear', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableComposePreview(page);

    await swipeCompose(page, 'edit-me');
    await page.screenshot({ path: path.join(SM_DIR, '15-previewing-before-tap.png') });

    await expect(page.locator('#imeInput')).toHaveClass(/ime-visible/);
    await page.locator('#imeInput').dispatchEvent('touchstart', { bubbles: true });
    await page.waitForTimeout(100);
    await page.screenshot({ path: path.join(SM_DIR, '16-editing-after-tap.png') });

    await expect(page.locator('#imeInput')).toHaveClass(/ime-editing/);

    // Wait beyond the 5s auto-clear timeout
    await page.waitForTimeout(6000);
    await page.screenshot({ path: path.join(SM_DIR, '17-editing-after-6s.png') });

    const imeVal = await page.evaluate(() => document.getElementById('imeInput').value);
    expect(imeVal).toContain('edit-me');
  });

  test('without preview: compose sends immediately, textarea stays hidden', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await page.evaluate(() => {
      const btn = document.getElementById('composeModeBtn');
      if (btn) btn.click();
    });
    await page.waitForTimeout(100);
    await page.screenshot({ path: path.join(SM_DIR, '18-compose-no-preview.png') });
    await page.evaluate(() => { window.__mockWsSpy = []; });

    await swipeCompose(page, 'immediate');
    await page.waitForTimeout(100);

    // Text was sent to SSH immediately
    const msgs = await getInputMessages(page);
    expect(msgs.some((m) => m.data.includes('immediate'))).toBe(true);
    // Textarea stays alive briefly (1.5s deferred idle for voice continuity)
    // then hides after the deferred idle fires
    await expect(page.locator('#imeInput')).not.toHaveClass(/ime-visible/, { timeout: 3000 });
    await page.screenshot({ path: path.join(SM_DIR, '19-after-immediate-send.png') });
    // Action buttons must be hidden
    await expect(page.locator('#imeActions')).toHaveClass(/hidden/);
  });

  test('eye button hidden when compose is off', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await page.screenshot({ path: path.join(SM_DIR, '20-compose-off-eye-hidden.png') });
    await expect(page.locator('#previewModeBtn')).toHaveClass(/hidden/);
  });

  test('no stale text after commit — subsequent compose starts clean', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableComposePreview(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    // Compose and commit first word
    await swipeCompose(page, 'first');
    await page.screenshot({ path: path.join(SM_DIR, '21-first-word-preview.png') });
    await page.locator('#imeCommitBtn').click();
    await page.waitForTimeout(100);
    await page.screenshot({ path: path.join(SM_DIR, '22-after-first-commit.png') });

    // Textarea must be empty and hidden after commit
    await expect(page.locator('#imeInput')).not.toHaveClass(/ime-visible/);
    const val1 = await page.evaluate(() => document.getElementById('imeInput').value);
    expect(val1).toBe('');

    // Compose second word — should start clean, no "first" lingering
    await swipeCompose(page, 'second');
    await page.waitForTimeout(100);
    await page.screenshot({ path: path.join(SM_DIR, '23-second-word-clean.png') });

    const val2 = await page.evaluate(() => document.getElementById('imeInput').value);
    expect(val2).not.toContain('first');
    expect(val2).toContain('second');
    await expect(page.locator('#imeInput')).toHaveClass(/ime-visible/);
  });

  test('textarea auto-resizes as text grows (#167)', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableComposePreview(page);

    // Compose a short word and record height
    await swipeCompose(page, 'hi');
    await page.waitForTimeout(100);
    const shortHeight = await page.locator('#imeInput').evaluate((el) => el.offsetHeight);

    // Compose several more words to force wrapping
    await swipeCompose(page, 'this is a much longer sentence that should cause the textarea to grow');
    await swipeCompose(page, 'and even more words to fill up the available space nicely');
    await page.waitForTimeout(100);
    const tallHeight = await page.locator('#imeInput').evaluate((el) => el.offsetHeight);

    expect(tallHeight).toBeGreaterThan(shortHeight);

    // Commit text and verify textarea shrinks back
    await page.locator('#imeCommitBtn').click();
    await page.waitForTimeout(100);
    // After commit, textarea goes to idle (hidden), height reset
    const afterCommitHeight = await page.locator('#imeInput').evaluate((el) => el.style.height);
    expect(afterCommitHeight).toBe('');
  });

  test('compose without preview: text not re-shown when eye toggled on', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    // Compose ON, preview OFF
    await page.evaluate(() => {
      const btn = document.getElementById('composeModeBtn');
      if (btn) btn.click();
    });
    await page.waitForTimeout(100);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    // Swipe a word — sends immediately, no preview
    await swipeCompose(page, 'gone');
    await page.waitForTimeout(200);
    await page.screenshot({ path: path.join(SM_DIR, '24-after-no-preview-send.png') });

    // Now toggle eye ON — textarea must NOT show stale "gone" text
    await page.evaluate(() => {
      const btn = document.getElementById('previewModeBtn');
      if (btn) btn.click();
    });
    await page.waitForTimeout(100);
    await page.screenshot({ path: path.join(SM_DIR, '25-eye-on-no-stale.png') });

    // Textarea should be empty and hidden (no stale text from previous send)
    await expect(page.locator('#imeInput')).not.toHaveClass(/ime-visible/);
    const val = await page.evaluate(() => document.getElementById('imeInput').value);
    expect(val).toBe('');
  });
});

// ── IME cursor-based auto-positioning (#106) ──────────────────────────────────

test.describe('IME auto-positioning based on cursor (#106)', { tag: '@device-critical' }, () => {
  /**
   * Stub appState.terminal with a fake buffer so _effectiveDock() can read
   * cursorY and rows without a real xterm instance.
   */
  async function stubTerminalCursor(page, cursorY, rows) {
    await page.evaluate(({ cy, r }) => {
      // Access appState via the module (already loaded by the app)
      // We mock it by patching the object in place using a dynamic import
      return import('./modules/state.js').then(({ appState: state }) => {
        if (!state.terminal) {
          // Create a minimal stub if no real terminal
          state.terminal = {
            buffer: { active: { cursorY: cy } },
            rows: r,
          };
        } else {
          // Override cursor position on the real terminal buffer proxy
          Object.defineProperty(state.terminal.buffer.active, 'cursorY', {
            get: () => cy, configurable: true,
          });
          Object.defineProperty(state.terminal, 'rows', {
            get: () => r, configurable: true,
          });
        }
      });
    }, { cy: cursorY, r: rows });
  }

  test('cursor in top half → IME preview positioned at bottom', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableComposePreview(page);

    // Place cursor in top half (row 3 of 24 rows)
    await stubTerminalCursor(page, 3, 24);

    await swipeCompose(page, 'hello');
    await page.waitForTimeout(100);

    // IME should be visible and positioned at bottom (bottom style set, top = 'auto')
    await expect(page.locator('#imeInput')).toHaveClass(/ime-visible/);
    const imeStyle = await page.locator('#imeInput').evaluate((el) => ({
      bottom: el.style.bottom,
      top: el.style.top,
    }));
    expect(imeStyle.top).toBe('auto');
    expect(imeStyle.bottom).not.toBe('');
    expect(imeStyle.bottom).not.toBe('auto');
  });

  test('cursor in bottom half → IME preview positioned at top', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableComposePreview(page);

    // Place cursor in bottom half (row 20 of 24 rows)
    await stubTerminalCursor(page, 20, 24);

    await swipeCompose(page, 'world');
    await page.waitForTimeout(100);

    // IME should be visible and positioned at top (top style set, bottom = 'auto')
    await expect(page.locator('#imeInput')).toHaveClass(/ime-visible/);
    const imeStyle = await page.locator('#imeInput').evaluate((el) => ({
      bottom: el.style.bottom,
      top: el.style.top,
    }));
    expect(imeStyle.bottom).toBe('auto');
    expect(imeStyle.top).not.toBe('');
    expect(imeStyle.top).not.toBe('auto');
  });

  test('no terminal → defaults to stored _dockPosition (top)', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableComposePreview(page);

    // Remove terminal from appState to simulate disconnected state
    await page.evaluate(() => {
      return import('./modules/state.js').then(({ appState: state }) => {
        state.terminal = null;
      });
    });

    await swipeCompose(page, 'fallback');
    await page.waitForTimeout(100);

    // IME should be visible; default dock is 'top' (localStorage not set)
    await expect(page.locator('#imeInput')).toHaveClass(/ime-visible/);
    const imeStyle = await page.locator('#imeInput').evaluate((el) => ({
      bottom: el.style.bottom,
      top: el.style.top,
    }));
    // Default _dockPosition is 'top'
    expect(imeStyle.bottom).toBe('auto');
    expect(imeStyle.top).not.toBe('auto');
  });

  test('manual dock toggle overrides auto-positioning within same composition', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableComposePreview(page);

    // Cursor in top half → auto would pick bottom
    await stubTerminalCursor(page, 3, 24);
    await swipeCompose(page, 'test');
    await page.waitForTimeout(100);

    // Verify auto picked bottom
    const before = await page.locator('#imeInput').evaluate((el) => el.style.top);
    expect(before).toBe('auto');

    // User clicks dock toggle — should flip to top
    await page.locator('#imeDockToggle').click();
    await page.waitForTimeout(100);

    const after = await page.locator('#imeInput').evaluate((el) => ({
      bottom: el.style.bottom,
      top: el.style.top,
    }));
    expect(after.bottom).toBe('auto');
    expect(after.top).not.toBe('auto');
  });
});

// ── Issue #170 — ctrl+key in compose+preview mode ──────────────────────────────

test.describe('Issue #170 — sticky Ctrl in compose+preview sends control char', { tag: '@device-critical' }, () => {
  test('Ctrl (sticky) + letter in compose+preview sends control character immediately', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableComposePreview(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    // Activate sticky Ctrl, then press 'c' on the imeInput textarea
    await page.locator('#keyCtrl').click();
    await page.waitForTimeout(50);

    // Simulate keydown for 'c' on imeInput (as if user tapped the key)
    await page.evaluate(() => {
      const el = document.getElementById('imeInput');
      el.dispatchEvent(new KeyboardEvent('keydown', {
        bubbles: true, cancelable: true, key: 'c',
      }));
    });
    await page.waitForTimeout(100);

    const msgs = await getInputMessages(page);
    expect(msgs.some((m) => m.data === '\x03')).toBe(true); // ^C
  });

  test('ctrlActive resets after use in compose+preview mode', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableComposePreview(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    // Activate sticky Ctrl
    await page.locator('#keyCtrl').click();
    await page.waitForTimeout(50);

    // Send Ctrl+R
    await page.evaluate(() => {
      const el = document.getElementById('imeInput');
      el.dispatchEvent(new KeyboardEvent('keydown', {
        bubbles: true, cancelable: true, key: 'r',
      }));
    });
    await page.waitForTimeout(100);

    // ctrlActive should be reset — check that the Ctrl button is no longer active
    const ctrlActive = await page.evaluate(() => {
      return import('./modules/state.js').then(({ appState }) => appState.ctrlActive);
    });
    expect(ctrlActive).toBe(false);
  });
});

// ── Issue #172 — number keys in compose+preview mode ───────────────────────────

test.describe('Issue #172 — number keys in compose+preview send directly', { tag: '@device-critical' }, () => {
  test('number key in compose+preview sends to terminal immediately', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableComposePreview(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    // Press '3' on the imeInput textarea
    await page.evaluate(() => {
      const el = document.getElementById('imeInput');
      el.dispatchEvent(new KeyboardEvent('keydown', {
        bubbles: true, cancelable: true, key: '3',
      }));
    });
    await page.waitForTimeout(100);

    const msgs = await getInputMessages(page);
    expect(msgs.some((m) => m.data === '3')).toBe(true);
  });

  test('multiple number keys each send individually', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableComposePreview(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    // Press '1' then '5'
    await page.evaluate(() => {
      const el = document.getElementById('imeInput');
      el.dispatchEvent(new KeyboardEvent('keydown', {
        bubbles: true, cancelable: true, key: '1',
      }));
      el.dispatchEvent(new KeyboardEvent('keydown', {
        bubbles: true, cancelable: true, key: '5',
      }));
    });
    await page.waitForTimeout(100);

    const msgs = await getInputMessages(page);
    expect(msgs.some((m) => m.data === '1')).toBe(true);
    expect(msgs.some((m) => m.data === '5')).toBe(true);
  });

  test('alphabetic keys still go to textarea in compose+preview (not sent directly)', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableComposePreview(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    // Swipe a word — should be held in preview, not sent
    await swipeCompose(page, 'hello');
    await page.waitForTimeout(100);

    const msgs = await getInputMessages(page);
    expect(msgs).toHaveLength(0);
    const imeVal = await page.evaluate(() => document.getElementById('imeInput').value);
    expect(imeVal).toContain('hello');
  });
});

// ── Issue #129 — direct mode Enter key (#129) ─────────────────────────────────

test.describe('Issue #129 — direct mode Enter sends \\r', { tag: '@device-critical' }, () => {
  /**
   * Switch from compose mode (default after connect) to direct mode by
   * clicking the compose toggle, then focus #directInput.
   */
  async function enableDirectMode(page) {
    await page.evaluate(() => {
      const btn = document.getElementById('composeModeBtn');
      // composeModeBtn is active when imeMode (compose) is on — click to turn it off
      if (btn && btn.classList.contains('active')) btn.click();
    });
    await page.waitForTimeout(100);
    await page.locator('#directInput').focus().catch(() => {});
    await page.waitForTimeout(50);
  }

  test('directInput has enterkeyhint="send" for Gboard compatibility (#129)', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableDirectMode(page);

    const hint = await page.locator('#directInput').getAttribute('enterkeyhint');
    expect(hint).toBe('send');
  });

  test('Enter key in direct mode sends \\r via keydown KEY_MAP', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableDirectMode(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    // Press Enter — Playwright fires a real keydown with e.key === 'Enter'
    await page.locator('#directInput').press('Enter');
    await page.waitForTimeout(100);

    const msgs = await getInputMessages(page);
    expect(msgs.some((m) => m.data === '\r')).toBe(true);
  });

  test('insertLineBreak beforeinput in direct mode sends \\r', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableDirectMode(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    // Simulate Gboard-style insertLineBreak on the directInput field
    await page.evaluate(() => {
      const el = document.getElementById('directInput');
      el.dispatchEvent(new InputEvent('beforeinput', {
        bubbles: true, cancelable: true, inputType: 'insertLineBreak',
      }));
    });
    await page.waitForTimeout(100);

    const msgs = await getInputMessages(page);
    expect(msgs.some((m) => m.data === '\r')).toBe(true);
  });

  test('keydown with key=Unidentified keyCode=13 sends \\r (mobile fallback)', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableDirectMode(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    // Simulate mobile soft keyboard Enter: key='Unidentified', keyCode=13
    await page.evaluate(() => {
      const el = document.getElementById('directInput');
      el.dispatchEvent(new KeyboardEvent('keydown', {
        bubbles: true, cancelable: true, key: 'Unidentified', keyCode: 13,
      }));
    });
    await page.waitForTimeout(100);

    const msgs = await getInputMessages(page);
    expect(msgs.some((m) => m.data === '\r')).toBe(true);
  });

  test('characters still pass through after Enter in direct mode', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableDirectMode(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    // Type a character, press Enter, type another character
    await page.locator('#directInput').press('a');
    await page.locator('#directInput').press('Enter');
    await page.locator('#directInput').press('b');
    await page.waitForTimeout(100);

    const msgs = await getInputMessages(page);
    expect(msgs.some((m) => m.data === 'a')).toBe(true);
    expect(msgs.some((m) => m.data === '\r')).toBe(true);
    expect(msgs.some((m) => m.data === 'b')).toBe(true);
  });
});

// ── Issue #169 — Preview mode countdown timer on commit button (#169) ────────

test.describe('Issue #169 — preview mode countdown timer', { tag: '@device-critical' }, () => {

  test('countdown ring appears on commit button when preview text is present', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableComposePreview(page);

    // Commit button should not have countdown ring initially
    const hasCountdown = await page.locator('#imeCommitBtn').evaluate((el) => el.classList.contains('countdown-active'));
    expect(hasCountdown).toBe(false);

    // Swipe a word — countdown ring should appear on commit button
    await swipeCompose(page, 'hello world test sentence');
    await page.waitForTimeout(200);

    const countdownActive = await page.locator('#imeCommitBtn').evaluate((el) => el.classList.contains('countdown-active'));
    expect(countdownActive).toBe(true);

    // Countdown text should show remaining seconds
    const countdownText = await page.locator('#imeCommitBtn .commit-countdown').textContent();
    expect(Number(countdownText)).toBeGreaterThan(0);
  });

  test('countdown ring disappears when text is committed', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableComposePreview(page);

    await swipeCompose(page, 'commit me now please');
    await page.waitForTimeout(200);

    // Countdown ring is active
    const activeBefore = await page.locator('#imeCommitBtn').evaluate((el) => el.classList.contains('countdown-active'));
    expect(activeBefore).toBe(true);

    // Commit the text
    await page.locator('#imeCommitBtn').click();
    await page.waitForTimeout(200);

    // Countdown ring should be gone
    const activeAfter = await page.locator('#imeCommitBtn').evaluate((el) => el.classList.contains('countdown-active'));
    expect(activeAfter).toBe(false);
  });

  test('long-press on commit button cycles through durations', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableComposePreview(page);

    // Clear any stored duration
    await page.evaluate(() => { localStorage.removeItem('imePreviewTimeout'); });

    await swipeCompose(page, 'cycle duration test words');
    await page.waitForTimeout(200);

    // Default is 8s — long-press to cycle to 15s
    const commitBtn = page.locator('#imeCommitBtn');
    await commitBtn.dispatchEvent('pointerdown');
    await page.waitForTimeout(700);
    await commitBtn.dispatchEvent('pointerup');
    await page.waitForTimeout(100);
    let stored = await page.evaluate(() => localStorage.getItem('imePreviewTimeout'));
    expect(stored).toBe('15000');

    // Long-press again — cycle to Infinity
    await commitBtn.dispatchEvent('pointerdown');
    await page.waitForTimeout(700);
    await commitBtn.dispatchEvent('pointerup');
    await page.waitForTimeout(100);
    stored = await page.evaluate(() => localStorage.getItem('imePreviewTimeout'));
    expect(stored).toBe('Infinity');

    // Countdown should show infinity symbol
    const countdownText = await page.locator('#imeCommitBtn .commit-countdown').textContent();
    expect(countdownText).toBe('\u221E');

    // Long-press again — cycle to 4s
    await commitBtn.dispatchEvent('pointerdown');
    await page.waitForTimeout(700);
    await commitBtn.dispatchEvent('pointerup');
    await page.waitForTimeout(100);
    stored = await page.evaluate(() => localStorage.getItem('imePreviewTimeout'));
    expect(stored).toBe('4000');
  });

  test('duration persists across compositions', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableComposePreview(page);

    // Set duration to 15s
    await page.evaluate(() => { localStorage.setItem('imePreviewTimeout', '15000'); });

    await swipeCompose(page, 'persistence test sentence here');
    await page.waitForTimeout(200);

    // Countdown should show ~15 (seconds remaining at 15s timeout)
    const countdownText = await page.locator('#imeCommitBtn .commit-countdown').textContent();
    expect(Number(countdownText)).toBeGreaterThanOrEqual(13);
    expect(Number(countdownText)).toBeLessThanOrEqual(15);
  });

  test('never mode does not auto-commit', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableComposePreview(page);

    // Set duration to Infinity (never)
    await page.evaluate(() => { localStorage.setItem('imePreviewTimeout', 'Infinity'); });
    await page.evaluate(() => { window.__mockWsSpy = []; });

    await swipeCompose(page, 'should stay forever in preview');
    await page.waitForTimeout(5000);

    // Text should NOT have been sent
    const msgs = await getInputMessages(page);
    expect(msgs).toHaveLength(0);

    // Text should still be in the textarea
    const imeVal = await page.evaluate(() => document.getElementById('imeInput').value);
    expect(imeVal).toContain('should stay forever in preview');
  });
});

// ── Issue #166 — preview mode commit and timeout must send text (#166) ────────

test.describe('Issue #166 — preview mode commit and timeout send text', { tag: '@device-critical' }, () => {

  test('commit button in preview mode sends swipe-composed text via WebSocket', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableComposePreview(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    // Swipe-compose a multi-word sentence
    await swipeCompose(page, 'the quick brown fox jumps over');
    await page.waitForTimeout(200);

    // Text should be held in textarea, NOT sent yet
    const msgsBeforeCommit = await getInputMessages(page);
    expect(msgsBeforeCommit).toHaveLength(0);

    // Tap the commit button
    await page.locator('#imeCommitBtn').click();
    await page.waitForTimeout(200);

    // Text must have been sent to SSH via WebSocket
    const msgsAfterCommit = await getInputMessages(page);
    expect(msgsAfterCommit.some((m) => m.data.includes('the quick brown fox jumps over'))).toBe(true);
    // No trailing \r — commit sends text only
    expect(msgsAfterCommit.every((m) => m.data !== '\r')).toBe(true);
  });

  test('auto-commit timeout sends preview text to SSH after countdown expires', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableComposePreview(page);

    // Use shortest countdown (3s) for faster test; idle delay is 1.5s, total ~4.5s
    await page.evaluate(() => { localStorage.setItem('imePreviewTimeout', '3000'); });
    await page.evaluate(() => { window.__mockWsSpy = []; });

    await swipeCompose(page, 'auto-sent after timeout expires!');
    await page.waitForTimeout(200);

    // Text should be held — not sent yet
    const msgsBeforeTimeout = await getInputMessages(page);
    expect(msgsBeforeTimeout).toHaveLength(0);

    // Wait for idle delay (1.5s) + countdown (3s) + margin = ~5.5s
    await page.waitForTimeout(5500);

    // Text must have been auto-committed to SSH
    const msgsAfterTimeout = await getInputMessages(page);
    expect(msgsAfterTimeout.some((m) => m.data.includes('auto-sent after timeout expires!'))).toBe(true);

    // Textarea should be cleared and hidden after auto-commit
    const imeVal = await page.evaluate(() => document.getElementById('imeInput').value);
    expect(imeVal).toBe('');
    await expect(page.locator('#imeInput')).not.toHaveClass(/ime-visible/);
  });
});

// ── Issue #136 — backspace on empty preview forwards DEL to terminal (#136) ──

test.describe('Issue #136 — backspace on empty preview forwards to terminal', { tag: '@device-critical' }, () => {

  test('backspace in empty preview textarea sends \\x7f to SSH', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableComposePreview(page);

    // Compose text and commit it — text is sent, textarea becomes empty
    await swipeCompose(page, 'deleteme');
    await page.waitForTimeout(200);
    await page.locator('#imeCommitBtn').click();
    await page.waitForTimeout(200);

    // Verify textarea is now empty
    const imeVal = await page.evaluate(() => document.getElementById('imeInput').value);
    expect(imeVal).toBe('');

    // Clear spy to isolate the backspace
    await page.evaluate(() => { window.__mockWsSpy = []; });

    // Focus the textarea and press Backspace
    await page.locator('#imeInput').focus();
    await page.waitForTimeout(100);
    await page.locator('#imeInput').press('Backspace');
    await page.waitForTimeout(200);

    // Verify DEL (\x7f) was sent to the terminal
    const msgs = await getInputMessages(page);
    expect(msgs.length).toBeGreaterThanOrEqual(1);
    expect(msgs.some((m) => m.data === '\x7f')).toBe(true);
  });
});

// ── Issue #137 — commit button sends text after voice input (#137) ──────────

test.describe('Issue #137 — commit button sends text after voice input', { tag: '@device-critical' }, () => {

  test('voice composition text is sent via commit button', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableComposePreview(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    // Simulate voice dictation: compositionstart, value set, compositionend
    // Voice input typically sets the full text at once (no incremental updates)
    await page.evaluate(() => {
      const el = document.getElementById('imeInput');
      el.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
      el.value = 'hello from voice dictation';
      el.dispatchEvent(new CompositionEvent('compositionend', {
        bubbles: true, data: 'hello from voice dictation',
      }));
    });
    await page.waitForTimeout(200);

    // Verify text is in the textarea
    const imeVal = await page.evaluate(() => document.getElementById('imeInput').value);
    expect(imeVal).toContain('hello from voice dictation');

    // Nothing sent yet (preview mode holds text)
    const msgsBefore = await getInputMessages(page);
    expect(msgsBefore).toHaveLength(0);

    // Click commit button
    await page.locator('#imeCommitBtn').click();
    await page.waitForTimeout(200);

    // Text must have been sent to SSH
    const msgsAfter = await getInputMessages(page);
    expect(msgsAfter.some((m) => m.data.includes('hello from voice dictation'))).toBe(true);
    // No trailing \r — commit sends text only
    expect(msgsAfter.every((m) => m.data !== '\r')).toBe(true);
  });

  test('voice input with empty e.data but textarea has text — commit still sends', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableComposePreview(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    // Voice dictation quirk: compositionend fires with empty data,
    // but the textarea value has the full dictated text
    await page.evaluate(() => {
      const el = document.getElementById('imeInput');
      el.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
      el.value = 'voice text with empty data field';
      el.dispatchEvent(new CompositionEvent('compositionend', {
        bubbles: true, data: '',
      }));
    });
    await page.waitForTimeout(200);

    // Verify text is held in textarea
    const imeVal = await page.evaluate(() => document.getElementById('imeInput').value);
    expect(imeVal).toContain('voice text with empty data field');

    // Click commit button
    await page.locator('#imeCommitBtn').click();
    await page.waitForTimeout(200);

    // Text must have been sent
    const msgs = await getInputMessages(page);
    expect(msgs.some((m) => m.data.includes('voice text with empty data field'))).toBe(true);
  });
});

// ── Issue #132 — voice input auto-preview and no premature clear (#132) ─────

test.describe('Issue #132 — voice input auto-preview on first use', { tag: '@device-critical' }, () => {

  test('first voice composition triggers preview display (ime-visible)', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableComposePreview(page);

    // Verify textarea is NOT visible before any composition
    await expect(page.locator('#imeInput')).not.toHaveClass(/ime-visible/);

    // Simulate first-ever voice composition
    await page.evaluate(() => {
      const el = document.getElementById('imeInput');
      el.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
      el.value = 'first voice input ever';
      el.dispatchEvent(new CompositionEvent('compositionend', {
        bubbles: true, data: 'first voice input ever',
      }));
    });
    await page.waitForTimeout(200);

    // Textarea must become visible (ime-visible class added)
    await expect(page.locator('#imeInput')).toHaveClass(/ime-visible/);
    // Action buttons must be visible
    await expect(page.locator('#imeActions')).not.toHaveClass(/hidden/);
  });

  test('voice input text is NOT auto-cleared within 2s (preview holds)', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableComposePreview(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    // Set a long countdown to avoid auto-commit interfering
    await page.evaluate(() => { localStorage.setItem('imePreviewTimeout', 'Infinity'); });

    // Simulate voice composition
    await page.evaluate(() => {
      const el = document.getElementById('imeInput');
      el.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
      el.value = 'do not clear this text prematurely';
      el.dispatchEvent(new CompositionEvent('compositionend', {
        bubbles: true, data: 'do not clear this text prematurely',
      }));
    });
    await page.waitForTimeout(200);

    // Text should be in the textarea
    const imeVal1 = await page.evaluate(() => document.getElementById('imeInput').value);
    expect(imeVal1).toContain('do not clear this text prematurely');

    // Wait 2 seconds — text must still be there (not auto-cleared)
    await page.waitForTimeout(2000);

    const imeVal2 = await page.evaluate(() => document.getElementById('imeInput').value);
    expect(imeVal2).toContain('do not clear this text prematurely');

    // Textarea must still be visible
    await expect(page.locator('#imeInput')).toHaveClass(/ime-visible/);

    // Nothing should have been sent to SSH yet
    const msgs = await getInputMessages(page);
    expect(msgs).toHaveLength(0);
  });

  test('voice composition shows textarea even on compositionstart (preview mode)', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableComposePreview(page);

    // Simulate just compositionstart (voice recognition starting)
    await page.evaluate(() => {
      const el = document.getElementById('imeInput');
      el.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
    });
    await page.waitForTimeout(200);

    // Textarea should become visible immediately during composition
    await expect(page.locator('#imeInput')).toHaveClass(/ime-visible/);
  });
});

// ── Issue #135 — voice typing captures only first word ──────────────────────

test.describe('Issue #135 — voice typing multi-word composition', { tag: '@device-critical' }, () => {

  /**
   * Simulate voice dictation: compositionstart, compositionupdate with partial
   * text, then compositionend with the full multi-word phrase. Voice engines
   * typically send partial updates (first word) then deliver the full text on
   * compositionend. The textarea value is set to the full text at the end.
   */
  async function voiceCompose(page, partialText, fullText) {
    await page.evaluate(({ partial, full }) => {
      const el = document.getElementById('imeInput');
      el.focus();
      el.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
      // Voice engine sends partial updates (first word only)
      el.value = partial;
      el.dispatchEvent(new CompositionEvent('compositionupdate', {
        bubbles: true, data: partial,
      }));
      // Voice engine delivers full text on compositionend
      el.value = full;
      el.dispatchEvent(new CompositionEvent('compositionend', {
        bubbles: true, data: full,
      }));
    }, { partial: partialText, full: fullText });
    await page.waitForTimeout(100);
  }

  test('compose+preview holds full multi-word voice text, not just first word', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableComposePreview(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    await voiceCompose(page, 'hello', 'hello world');

    // Full text must be in the textarea (not truncated to first word)
    const imeVal = await page.evaluate(() => document.getElementById('imeInput').value);
    expect(imeVal).toBe('hello world');

    // Nothing should be sent yet (preview holds text)
    const msgs = await getInputMessages(page);
    expect(msgs).toHaveLength(0);

    // Action buttons should be visible for the user to commit
    await expect(page.locator('#imeActions')).not.toHaveClass(/hidden/);
  });

  test('voice text survives 2s without being cleared by timer', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableComposePreview(page);

    // Use "never" timeout so auto-commit doesn't interfere
    await page.evaluate(() => { localStorage.setItem('imePreviewTimeout', 'Infinity'); });
    await page.evaluate(() => { window.__mockWsSpy = []; });

    await voiceCompose(page, 'the', 'the quick brown fox');

    // Wait 2 seconds — text must still be there (timer must not clear it early)
    await page.waitForTimeout(2000);

    const imeVal = await page.evaluate(() => document.getElementById('imeInput').value);
    expect(imeVal).toBe('the quick brown fox');

    // Still not sent
    const msgs = await getInputMessages(page);
    expect(msgs).toHaveLength(0);
  });

  test('non-preview mode sends full voice text immediately', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    // Compose ON, preview OFF
    await page.evaluate(() => {
      const btn = document.getElementById('composeModeBtn');
      if (btn) btn.click();
    });
    await page.waitForTimeout(100);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    await voiceCompose(page, 'good', 'good morning everyone');

    const msgs = await getInputMessages(page);
    expect(msgs.some((m) => m.data.includes('good morning everyone'))).toBe(true);
  });
});

// ── Issue #163 — compositionend e.data populates ime.value ──────────────────

test.describe('Issue #163 — compositionend e.data fallback', { tag: '@device-critical' }, () => {

  test('compositionend with e.data fills textarea when ime.value is empty', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    // Simulate voice dictation where ime.value stays empty but e.data has text
    await page.evaluate(() => {
      const el = document.getElementById('imeInput');
      el.focus();
      el.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
      // Crucially: do NOT set el.value — simulates the voice quirk
      el.dispatchEvent(new CompositionEvent('compositionend', {
        bubbles: true, data: 'test phrase',
      }));
    });
    await page.waitForTimeout(100);

    // The code uses `ime.value || e.data` so e.data should be used as fallback
    // and the text should be sent to SSH
    const msgs = await getInputMessages(page);
    expect(msgs.some((m) => m.data === 'test phrase')).toBe(true);
  });

  test('compose+preview mode captures e.data when ime.value is empty', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await enableComposePreview(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    // In compose+preview, compositionend with empty value but e.data present
    await page.evaluate(() => {
      const el = document.getElementById('imeInput');
      el.focus();
      el.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
      // Voice quirk: value stays empty, e.data has text
      el.dispatchEvent(new CompositionEvent('compositionend', {
        bubbles: true, data: 'voice dictated sentence',
      }));
    });
    await page.waitForTimeout(100);

    // In preview mode, text should be held (not sent)
    const msgs = await getInputMessages(page);
    expect(msgs).toHaveLength(0);

    // The textarea must have the text for the user to see and commit
    const imeVal = await page.evaluate(() => document.getElementById('imeInput').value);
    expect(imeVal).toContain('voice dictated sentence');
  });
});
