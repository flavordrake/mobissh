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

test.describe('Issue #74 — compose action buttons Clear and Send', () => {
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

test.describe('IME state machine — compose + preview (#106)', () => {

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

test.describe('IME auto-positioning based on cursor (#106)', () => {
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
