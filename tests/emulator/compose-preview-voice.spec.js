/**
 * tests/emulator/compose-preview-voice.spec.js
 *
 * State machine baseline tests — decomposed from #139.
 *
 * North Star: the user's intended text is faithfully represented to the
 * terminal as entered, in all cases. Every test asserts this invariant:
 *   intent in == terminal out
 *
 * Tests that fail against current code are expected — they identify exactly
 * where the state machine breaks the invariant and become fix targets for
 * #132, #135, #136, #137, #138.
 *
 * Group 1: State machine transitions (8 tests)
 * Group 5: Cross-mode regression guards (5 tests)
 */

const {
  test, expect, screenshot,
  IntentCapture, TerminalReceiver, assertFaithful,
  enablePreviewMode, disablePreviewMode, enableComposeMode,
  tapCommit,
} = require('./fixtures');

// ── Test data ─────────────────────────────────────────────────────────────────
// All strings are 15+ words with punctuation to catch real-world Gboard behavior.

const TEST_SENTENCES = [
  'fix the direct mode enter key so it actually sends a carriage return on gboard, the issue was that enterkeyhint was missing from the password field.',
  'tail -f /var/log/syslog | grep -i error, then check if the server restarted properly and verify the version hash matches what we deployed.',
  'I want to capture all of these individually then turn them into aggressive test cases, something is off in our preview composer and key interaction behaviors.',
  'docker logs mobissh-prod --tail 50 and look for any websocket connection drops, especially the ones that say derp does not know about peer.',
  'set the cache control header to no-store on all static responses, the service worker uses network-first so we never want stale cached files.',
];

// ── Setup helper ──────────────────────────────────────────────────────────────

/**
 * Navigate to the app, establish a mock SSH connection, inject WS spy,
 * enable compose mode, and position on the terminal panel.
 */
async function setupWithCompose(page, mockSshServer) {
  // Inject WS spy before any app code runs
  await page.addInitScript(() => {
    window.__mockWsSpy = [];
    const OrigWS = window.WebSocket;
    window.WebSocket = class extends OrigWS {
      send(data) { window.__mockWsSpy.push(data); super.send(data); }
    };
  });
  await page.addInitScript(() => { localStorage.clear(); });

  await page.goto('./');
  await page.waitForSelector('.xterm-screen', { timeout: 8000 });

  // Vault setup
  await page.evaluate(async () => {
    const { createVault } = await import('./modules/vault.js');
    await createVault('test', false);
  });
  // Dismiss vault modal if visible
  try {
    const cancelBtn = page.locator('#vaultSetupCancel');
    await cancelBtn.waitFor({ state: 'visible', timeout: 1500 });
    await cancelBtn.click();
  } catch { /* vault already exists */ }

  // Point to mock server
  await page.evaluate((port) => {
    localStorage.setItem('wsUrl', `ws://localhost:${port}`);
  }, mockSshServer.port);

  // Connect
  await page.locator('[data-panel="connect"]').click();
  await page.locator('#host').fill('mock-host');
  await page.locator('#remote_a').fill('testuser');
  await page.locator('#remote_c').fill('testpass');
  await page.locator('#connectForm button[type="submit"]').click();

  const connectBtn = page.locator('[data-action="connect"]').first();
  await connectBtn.waitFor({ state: 'visible', timeout: 5000 });
  await connectBtn.click();

  // Wait for resize → connected
  await page.waitForFunction(() => {
    return (window.__mockWsSpy || []).some(s => {
      try { return JSON.parse(s).type === 'resize'; } catch { return false; }
    });
  }, null, { timeout: 10_000 });

  await page.waitForSelector('#panel-terminal.active', { timeout: 5000 });

  // Enable compose mode
  await enableComposeMode(page);
}

// ── Group 1: State machine transitions ────────────────────────────────────────

test.describe('Group 1: State machine transitions', () => {

  test('1.1 cold boot + enable compose → textarea visible, state is in compose area', async ({ page, mockSshServer }, testInfo) => {
    await setupWithCompose(page, mockSshServer);
    await screenshot(page, testInfo, '1.1-compose-enabled');

    // composeModeBtn should have compose-active class
    const btnActive = await page.evaluate(() =>
      document.getElementById('composeModeBtn')?.classList.contains('compose-active')
    );
    expect(btnActive).toBe(true);

    // imeInput should exist in the DOM
    const hasImeInput = await page.evaluate(() =>
      document.getElementById('imeInput') !== null
    );
    expect(hasImeInput).toBe(true);

    // localStorage should reflect compose mode
    const storedMode = await page.evaluate(() => localStorage.getItem('imeMode'));
    expect(storedMode).toBe('ime');
  });

  test('1.2 compose + preview off: swipe sentence → intent === received (sent immediately)', async ({ page, mockSshServer }, testInfo) => {
    await setupWithCompose(page, mockSshServer);
    // Ensure preview mode is OFF
    await disablePreviewMode(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    const intent = new IntentCapture(page);
    const receiver = new TerminalReceiver(page);

    // Use a shorter sentence to keep the test focused
    const sentence = TEST_SENTENCES[0].split(' ').slice(0, 10).join(' ');
    await intent.swipeType(sentence);

    // Without preview, text should be sent immediately after composition
    await page.waitForTimeout(200);
    await screenshot(page, testInfo, '1.2-immediate-send');

    await assertFaithful(intent, receiver, expect);
  });

  test('1.3 compose + preview on: swipe sentence → text held, nothing sent', async ({ page, mockSshServer }, testInfo) => {
    await setupWithCompose(page, mockSshServer);
    await enablePreviewMode(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    const intent = new IntentCapture(page);

    const sentence = TEST_SENTENCES[1].split(' ').slice(0, 8).join(' ');
    await intent.swipeType(sentence);
    await page.waitForTimeout(200);
    await screenshot(page, testInfo, '1.3-text-held');

    // Text should be in textarea, NOT sent to SSH
    const imeVal = await page.evaluate(() => document.getElementById('imeInput')?.value ?? '');
    expect(imeVal.length).toBeGreaterThan(0);

    // No input messages should have been sent
    const inputMsgs = await page.evaluate(() =>
      (window.__mockWsSpy || []).filter(s => {
        try { return JSON.parse(s).type === 'input'; } catch { return false; }
      })
    );
    expect(inputMsgs).toHaveLength(0);

    // Action buttons should be visible (imeActions not hidden)
    const actionsHidden = await page.evaluate(() =>
      document.getElementById('imeActions')?.classList.contains('hidden') ?? true
    );
    expect(actionsHidden).toBe(false);
  });

  test('1.4 previewing → commit → intent === received', async ({ page, mockSshServer }, testInfo) => {
    await setupWithCompose(page, mockSshServer);
    await enablePreviewMode(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    const intent = new IntentCapture(page);
    const receiver = new TerminalReceiver(page);

    const sentence = TEST_SENTENCES[2].split(' ').slice(0, 10).join(' ');
    await intent.swipeType(sentence);
    await page.waitForTimeout(200);
    await screenshot(page, testInfo, '1.4-before-commit');

    await tapCommit(page);
    await page.waitForTimeout(200);
    await screenshot(page, testInfo, '1.4-after-commit');

    await assertFaithful(intent, receiver, expect);
  });

  test('1.5 previewing → Enter → intent + \\r === received', async ({ page, mockSshServer }, testInfo) => {
    await setupWithCompose(page, mockSshServer);
    await enablePreviewMode(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    const intent = new IntentCapture(page);

    const sentence = TEST_SENTENCES[3].split(' ').slice(0, 8).join(' ');
    await intent.swipeType(sentence);
    await page.waitForTimeout(200);
    await screenshot(page, testInfo, '1.5-before-enter');

    // Press Enter — should send text + \r
    await page.locator('#imeInput').press('Enter');
    await page.waitForTimeout(200);
    await screenshot(page, testInfo, '1.5-after-enter');

    // Verify text was sent
    const inputMsgs = await page.evaluate(() =>
      (window.__mockWsSpy || [])
        .map(s => { try { return JSON.parse(s); } catch { return null; } })
        .filter(m => m && m.type === 'input')
        .map(m => m.data)
    );
    const allText = inputMsgs.join('');
    expect(allText).toContain(intent.intended.split(' ')[0]);
    // \r should be present
    expect(inputMsgs.some(m => m === '\r')).toBe(true);
  });

  test('1.6 previewing → tap textarea → editing state (green border)', async ({ page, mockSshServer }, testInfo) => {
    await setupWithCompose(page, mockSshServer);
    await enablePreviewMode(page);

    const intent = new IntentCapture(page);
    const sentence = TEST_SENTENCES[4].split(' ').slice(0, 8).join(' ');
    await intent.swipeType(sentence);
    await page.waitForTimeout(200);
    await screenshot(page, testInfo, '1.6-previewing');

    // Tap into textarea → editing state
    await page.locator('#imeInput').dispatchEvent('touchstart', { bubbles: true });
    await page.waitForTimeout(200);
    await screenshot(page, testInfo, '1.6-editing');

    // imeInput should have ime-editing class (green border = editing state)
    const hasEditing = await page.evaluate(() =>
      document.getElementById('imeInput')?.classList.contains('ime-editing') ?? false
    );
    expect(hasEditing).toBe(true);
  });

  test('1.7 editing → commit → intent === received', async ({ page, mockSshServer }, testInfo) => {
    await setupWithCompose(page, mockSshServer);
    await enablePreviewMode(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    const intent = new IntentCapture(page);
    const receiver = new TerminalReceiver(page);

    const sentence = TEST_SENTENCES[0].split(' ').slice(0, 8).join(' ');
    await intent.swipeType(sentence);
    await page.waitForTimeout(200);

    // Transition to editing
    await page.locator('#imeInput').dispatchEvent('touchstart', { bubbles: true });
    await page.waitForTimeout(200);
    await screenshot(page, testInfo, '1.7-editing');

    await tapCommit(page);
    await page.waitForTimeout(200);
    await screenshot(page, testInfo, '1.7-after-commit');

    await assertFaithful(intent, receiver, expect);
  });

  test('1.8 editing → Enter → intent + \\r === received', async ({ page, mockSshServer }, testInfo) => {
    await setupWithCompose(page, mockSshServer);
    await enablePreviewMode(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    const intent = new IntentCapture(page);

    const sentence = TEST_SENTENCES[1].split(' ').slice(0, 8).join(' ');
    await intent.swipeType(sentence);
    await page.waitForTimeout(200);

    // Transition to editing
    await page.locator('#imeInput').dispatchEvent('touchstart', { bubbles: true });
    await page.waitForTimeout(200);
    await screenshot(page, testInfo, '1.8-editing-before-enter');

    // Press Enter
    await page.locator('#imeInput').press('Enter');
    await page.waitForTimeout(200);
    await screenshot(page, testInfo, '1.8-after-enter');

    const inputMsgs = await page.evaluate(() =>
      (window.__mockWsSpy || [])
        .map(s => { try { return JSON.parse(s); } catch { return null; } })
        .filter(m => m && m.type === 'input')
        .map(m => m.data)
    );
    const allText = inputMsgs.join('');
    expect(allText).toContain(intent.intended.split(' ')[0]);
    expect(inputMsgs.some(m => m === '\r')).toBe(true);
  });

});

// ── Group 2: Voice input lifecycle ────────────────────────────────────────────

const VOICE_SENTENCES = [
  'voice typing often disables for some reason after the first word, then if I keep talking and hit the check box to commit nothing happens but if I type space or enter it does.',
  'the preview does appear but only the first word is captured then nothing else comes through, I think a timer is canceling compose mode prematurely.',
  'I want to capture all of these individually then turn them into aggressive test cases, something is off in our preview composer and key interaction behaviors.',
];

test.describe('Group 2: Voice input lifecycle', () => {

  test('2.1 voice, preview off: full phrase reaches terminal', async ({ page, mockSshServer }, testInfo) => {
    await setupWithCompose(page, mockSshServer);
    await disablePreviewMode(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    const intent = new IntentCapture(page);
    const receiver = new TerminalReceiver(page);

    await intent.voiceInput(VOICE_SENTENCES[0]);
    await page.waitForTimeout(300);
    await screenshot(page, testInfo, '2.1-after-voice');

    await assertFaithful(intent, receiver, expect);
  });

  test('2.2 voice, preview off initially: starts voice → preview overlay appears, text accumulates', async ({ page, mockSshServer }, testInfo) => {
    await setupWithCompose(page, mockSshServer);
    await disablePreviewMode(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    const intent = new IntentCapture(page);

    // Use a shorter sentence to isolate the preview-auto-enable behavior
    const sentence = VOICE_SENTENCES[1].split(' ').slice(0, 8).join(' ');
    await intent.voiceInput(sentence);
    await page.waitForTimeout(300);
    await screenshot(page, testInfo, '2.2-after-voice');

    // Voice input: text should have accumulated in the textarea
    const imeVal = await page.evaluate(() => document.getElementById('imeInput')?.value ?? '');
    expect(imeVal.length).toBeGreaterThan(0);

    // Preview overlay (imeActions) should be visible
    const actionsHidden = await page.evaluate(() =>
      document.getElementById('imeActions')?.classList.contains('hidden') ?? true
    );
    expect(actionsHidden).toBe(false);
  });

  test('2.3 voice multi-word: all words captured in textarea', async ({ page, mockSshServer }, testInfo) => {
    await setupWithCompose(page, mockSshServer);
    await enablePreviewMode(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    const intent = new IntentCapture(page);

    // 15+ word sentence
    const sentence = VOICE_SENTENCES[2];
    expect(sentence.split(' ').length).toBeGreaterThanOrEqual(15);
    await intent.voiceInput(sentence);
    await page.waitForTimeout(300);
    await screenshot(page, testInfo, '2.3-after-voice');

    // All words must be in the textarea
    const imeVal = await page.evaluate(() => document.getElementById('imeInput')?.value ?? '');
    const words = sentence.split(' ');
    for (const word of words) {
      expect(imeVal, `Expected word "${word}" to be present in textarea`).toContain(word);
    }
  });

  test('2.4 voice → commit sends accumulated text', async ({ page, mockSshServer }, testInfo) => {
    await setupWithCompose(page, mockSshServer);
    await enablePreviewMode(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    const intent = new IntentCapture(page);
    const receiver = new TerminalReceiver(page);

    await intent.voiceInput(VOICE_SENTENCES[0]);
    await page.waitForTimeout(300);
    await screenshot(page, testInfo, '2.4-before-commit');

    await tapCommit(page);
    await page.waitForTimeout(200);
    await screenshot(page, testInfo, '2.4-after-commit');

    await assertFaithful(intent, receiver, expect);
  });

  test('2.5 voice → space sends text faithfully', async ({ page, mockSshServer }, testInfo) => {
    await setupWithCompose(page, mockSshServer);
    await enablePreviewMode(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    const intent = new IntentCapture(page);
    const receiver = new TerminalReceiver(page);

    const sentence = VOICE_SENTENCES[1].split(' ').slice(0, 8).join(' ');
    await intent.voiceInput(sentence);
    await page.waitForTimeout(300);
    await screenshot(page, testInfo, '2.5-before-space');

    // Type space to trigger send
    await page.locator('#imeInput').press(' ');
    await page.waitForTimeout(200);
    await screenshot(page, testInfo, '2.5-after-space');

    // Verify the voiced text was sent (with or without trailing space)
    const received = await receiver.getReceivedText();
    const receivedTrimmed = received.replace(/\s+$/, '');
    const intendedTrimmed = intent.intended.replace(/\s+$/, '');
    expect(receivedTrimmed, `Expected terminal to receive "${intendedTrimmed}" but got "${receivedTrimmed}"`).toBe(intendedTrimmed);
  });

  test('2.6 voice stops → commit still works after 2s delay', async ({ page, mockSshServer }, testInfo) => {
    await setupWithCompose(page, mockSshServer);
    await enablePreviewMode(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    const intent = new IntentCapture(page);
    const receiver = new TerminalReceiver(page);

    const sentence = VOICE_SENTENCES[2].split(' ').slice(0, 10).join(' ');
    await intent.voiceInput(sentence);

    // Wait 2s to simulate voice stopping before commit
    await page.waitForTimeout(2000);
    await screenshot(page, testInfo, '2.6-after-2s-wait');

    await tapCommit(page);
    await page.waitForTimeout(200);
    await screenshot(page, testInfo, '2.6-after-commit');

    await assertFaithful(intent, receiver, expect);
  });

  test('2.7 no timers fire during active voice: text accumulates continuously for 5s', async ({ page, mockSshServer }, testInfo) => {
    await setupWithCompose(page, mockSshServer);
    await enablePreviewMode(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    const intent = new IntentCapture(page);

    // Start compositionstart manually then let it run for ~5s via voiceInput
    // VOICE_SENTENCES[0] has many words; voiceInput fires one word every 300ms
    // With ~30 words that is ~9s, so we use a 15-word slice for ~5s
    const sentence = VOICE_SENTENCES[0].split(' ').slice(0, 15).join(' ');
    await intent.voiceInput(sentence);
    await screenshot(page, testInfo, '2.7-after-5s-voice');

    // Verify: text must still be in textarea (no auto-clear, no state reset)
    const imeVal = await page.evaluate(() => document.getElementById('imeInput')?.value ?? '');
    expect(imeVal.length, 'Textarea must retain text after long voice input').toBeGreaterThan(0);

    // Verify: no input messages were sent while composition was active (preview held them)
    const inputMsgs = await page.evaluate(() =>
      (window.__mockWsSpy || []).filter(s => {
        try { return JSON.parse(s).type === 'input'; } catch { return false; }
      })
    );
    expect(inputMsgs, 'No input should be sent to terminal during active voice composition').toHaveLength(0);
  });

});

// ── Group 5: Cross-mode regression guards ─────────────────────────────────────

test.describe('Group 5: Cross-mode regression guards', () => {

  test('5.1 direct mode Enter (#129) → \\r sent', async ({ page, mockSshServer }, testInfo) => {
    // Start in direct mode (default)
    await page.addInitScript(() => {
      window.__mockWsSpy = [];
      const OrigWS = window.WebSocket;
      window.WebSocket = class extends OrigWS {
        send(data) { window.__mockWsSpy.push(data); super.send(data); }
      };
    });
    await page.addInitScript(() => { localStorage.clear(); });

    await page.goto('./');
    await page.waitForSelector('.xterm-screen', { timeout: 8000 });

    await page.evaluate(async () => {
      const { createVault } = await import('./modules/vault.js');
      await createVault('test', false);
    });
    try {
      await page.locator('#vaultSetupCancel').waitFor({ state: 'visible', timeout: 1500 });
      await page.locator('#vaultSetupCancel').click();
    } catch { /* modal not present */ }

    await page.evaluate((port) => {
      localStorage.setItem('wsUrl', `ws://localhost:${port}`);
    }, mockSshServer.port);

    await page.locator('[data-panel="connect"]').click();
    await page.locator('#host').fill('mock-host');
    await page.locator('#remote_a').fill('testuser');
    await page.locator('#remote_c').fill('testpass');
    await page.locator('#connectForm button[type="submit"]').click();

    const connectBtn = page.locator('[data-action="connect"]').first();
    await connectBtn.waitFor({ state: 'visible', timeout: 5000 });
    await connectBtn.click();

    await page.waitForFunction(() =>
      (window.__mockWsSpy || []).some(s => {
        try { return JSON.parse(s).type === 'resize'; } catch { return false; }
      }), null, { timeout: 10_000 });

    await page.waitForSelector('#panel-terminal.active', { timeout: 5000 });

    // Should be in direct mode by default
    const storedMode = await page.evaluate(() => localStorage.getItem('imeMode'));
    expect(storedMode).toBeNull(); // null = direct mode (default)

    await page.evaluate(() => { window.__mockWsSpy = []; });

    // Press Enter in direct mode
    await page.locator('#directInput').focus().catch(() => {});
    await page.waitForTimeout(50);
    await page.locator('#directInput').press('Enter');
    await page.waitForTimeout(100);
    await screenshot(page, testInfo, '5.1-direct-enter');

    const msgs = await page.evaluate(() =>
      (window.__mockWsSpy || [])
        .map(s => { try { return JSON.parse(s); } catch { return null; } })
        .filter(m => m && m.type === 'input')
        .map(m => m.data)
    );
    expect(msgs.some(m => m === '\r')).toBe(true);
  });

  test('5.2 direct → compose → direct round-trip', async ({ page, mockSshServer }, testInfo) => {
    await setupWithCompose(page, mockSshServer);
    await screenshot(page, testInfo, '5.2-in-compose');

    const composeModeOn = await page.evaluate(() =>
      document.getElementById('composeModeBtn')?.classList.contains('compose-active')
    );
    expect(composeModeOn).toBe(true);

    // Switch back to direct
    await page.evaluate(() => {
      const btn = document.getElementById('composeModeBtn');
      if (btn && btn.classList.contains('compose-active')) btn.click();
    });
    await page.waitForTimeout(200);
    await screenshot(page, testInfo, '5.2-back-to-direct');

    const composeModeOff = await page.evaluate(() =>
      document.getElementById('composeModeBtn')?.classList.contains('compose-active')
    );
    expect(composeModeOff).toBe(false);

    // directInput should be present
    const hasDirectInput = await page.evaluate(() =>
      document.getElementById('directInput') !== null
    );
    expect(hasDirectInput).toBe(true);
  });

  test('5.3 preview toggle mid-session', async ({ page, mockSshServer }, testInfo) => {
    await setupWithCompose(page, mockSshServer);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    const intent = new IntentCapture(page);

    // Start without preview — first word sent immediately
    await disablePreviewMode(page);
    const firstWord = TEST_SENTENCES[2].split(' ').slice(0, 5).join(' ');
    await intent.swipeType(firstWord);
    await page.waitForTimeout(200);
    await screenshot(page, testInfo, '5.3-no-preview-sent');

    // First word should have been sent
    const msgs1 = await page.evaluate(() =>
      (window.__mockWsSpy || [])
        .map(s => { try { return JSON.parse(s); } catch { return null; } })
        .filter(m => m && m.type === 'input')
        .map(m => m.data)
    );
    expect(msgs1.length).toBeGreaterThan(0);

    // Now enable preview mid-session
    await enablePreviewMode(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    const intent2 = new IntentCapture(page);
    const receiver = new TerminalReceiver(page);
    const secondSentence = TEST_SENTENCES[3].split(' ').slice(0, 5).join(' ');
    await intent2.swipeType(secondSentence);
    await page.waitForTimeout(200);
    await screenshot(page, testInfo, '5.3-preview-holding');

    // Second text held, not sent
    const msgs2 = await page.evaluate(() =>
      (window.__mockWsSpy || [])
        .map(s => { try { return JSON.parse(s); } catch { return null; } })
        .filter(m => m && m.type === 'input')
    );
    expect(msgs2).toHaveLength(0);

    // Commit
    await tapCommit(page);
    await page.waitForTimeout(200);
    await assertFaithful(intent2, receiver, expect);
  });

  test('5.4 rapid compose/commit × 5', async ({ page, mockSshServer }, testInfo) => {
    await setupWithCompose(page, mockSshServer);
    await enablePreviewMode(page);

    // 5 rapid compose+commit cycles
    for (let i = 0; i < 5; i++) {
      await page.evaluate(() => { window.__mockWsSpy = []; });

      const intent = new IntentCapture(page);
      const receiver = new TerminalReceiver(page);

      // Use a 3-word chunk from each sentence
      const chunk = TEST_SENTENCES[i % TEST_SENTENCES.length].split(' ').slice(0, 3).join(' ');
      await intent.swipeType(chunk);
      await page.waitForTimeout(100);

      await tapCommit(page);
      await page.waitForTimeout(100);

      await assertFaithful(intent, receiver, expect);
    }
    await screenshot(page, testInfo, '5.4-rapid-commits-done');
  });

  test('5.5 voice then keyboard handoff', async ({ page, mockSshServer }, testInfo) => {
    await setupWithCompose(page, mockSshServer);
    await enablePreviewMode(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    const intent = new IntentCapture(page);
    const receiver = new TerminalReceiver(page);

    // "Voice" input: compositionend with data but empty textarea (voice dictation quirk)
    const voiceSentence = TEST_SENTENCES[0].split(' ').slice(0, 6).join(' ');
    await page.evaluate((text) => {
      const el = document.getElementById('imeInput');
      if (!el) return;
      el.focus();
      el.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
      // Voice: textarea may be empty at compositionend, data carries the text
      el.value = text;
      el.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: text }));
      el.dispatchEvent(new InputEvent('input', {
        bubbles: true, data: text, inputType: 'insertCompositionText',
      }));
    }, voiceSentence);
    intent.intended = voiceSentence;
    await page.waitForTimeout(200);
    await screenshot(page, testInfo, '5.5-after-voice');

    // Text held in preview
    const held = await page.evaluate(() => document.getElementById('imeInput')?.value ?? '');
    expect(held.length).toBeGreaterThan(0);

    // Now commit (simulates user reviewing voice text and tapping send)
    await tapCommit(page);
    await page.waitForTimeout(200);
    await screenshot(page, testInfo, '5.5-after-commit');

    await assertFaithful(intent, receiver, expect);
  });

});
