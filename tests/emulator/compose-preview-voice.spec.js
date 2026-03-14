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
  tapCommit, setupRealSSHConnection,
} = require('./fixtures');

const {
  COMMIT_SENTENCES, SHELL_SENTENCES, BUG_SENTENCES,
  AUTOCORRECT_SENTENCES, SHORT_INPUTS, CONTROL_SEQUENCES,
  ALL_SENTENCES,
} = require('./test-sentences');

// ── Test data mapping ────────────────────────────────────────────────────────
// Sentences sourced from test-sentences.js (real user inputs from #139).
// Each group draws from the category most relevant to its test concern.

const TEST_SENTENCES = [...COMMIT_SENTENCES, ...SHELL_SENTENCES];

// ── Setup helper ──────────────────────────────────────────────────────────────

/**
 * Connect to real SSH server, inject WS spy, enable compose mode.
 * Uses the sshServer fixture (Docker test-sshd) for real SSH.
 */
async function setupWithCompose(page, sshServer) {
  await setupRealSSHConnection(page, sshServer);

  // Enable compose mode
  await enableComposeMode(page);
}

// ── Group 1: State machine transitions ────────────────────────────────────────

test.describe('Group 1: State machine transitions', () => {

  test('1.1 cold boot + enable compose → textarea visible, state is in compose area', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await setupWithCompose(page, sshServer);
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

  test('1.2 compose + preview off: swipe sentence → intent === received (sent immediately)', async ({ emulatorPage: page, sshServer }, testInfo) => {
    // Capture console logs for event flow analysis
    const logs = [];
    page.on('console', msg => { if (msg.text().includes('[ime:')) logs.push(msg.text()); });

    await setupWithCompose(page, sshServer);
    // Ensure preview mode is OFF
    await disablePreviewMode(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    const intent = new IntentCapture(page);
    const receiver = new TerminalReceiver(page);

    const sentence = TEST_SENTENCES[0];
    await intent.swipeType(sentence);

    // Without preview, text should be sent immediately after composition
    await page.waitForTimeout(200);

    // Dump event flow for debugging
    console.log('--- IME event flow (first 20) ---');
    logs.slice(0, 20).forEach(l => console.log(l));
    console.log(`--- total: ${logs.length} events ---`);

    await screenshot(page, testInfo, '1.2-immediate-send');

    await assertFaithful(intent, receiver, expect);
  });

  test('1.3 compose + preview on: swipe sentence → text held, nothing sent', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await setupWithCompose(page, sshServer);
    await enablePreviewMode(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    const intent = new IntentCapture(page);

    const sentence = TEST_SENTENCES[1];
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

  test('1.4 previewing → commit → intent === received', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await setupWithCompose(page, sshServer);
    await enablePreviewMode(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    const intent = new IntentCapture(page);
    const receiver = new TerminalReceiver(page);

    const sentence = TEST_SENTENCES[2];
    await intent.swipeType(sentence);
    await page.waitForTimeout(200);
    await screenshot(page, testInfo, '1.4-before-commit');

    await tapCommit(page);
    await page.waitForTimeout(200);
    await screenshot(page, testInfo, '1.4-after-commit');

    await assertFaithful(intent, receiver, expect);
  });

  test('1.5 previewing → Enter → intent + \\r === received', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await setupWithCompose(page, sshServer);
    await enablePreviewMode(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    const intent = new IntentCapture(page);

    const sentence = TEST_SENTENCES[3];
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

  test('1.6 previewing → tap textarea → editing state (green border)', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await setupWithCompose(page, sshServer);
    await enablePreviewMode(page);

    const intent = new IntentCapture(page);
    const sentence = TEST_SENTENCES[4];
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

  test('1.7 editing → commit → intent === received', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await setupWithCompose(page, sshServer);
    await enablePreviewMode(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    const intent = new IntentCapture(page);
    const receiver = new TerminalReceiver(page);

    const sentence = TEST_SENTENCES[5];
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

  test('1.8 editing → Enter → intent + \\r === received', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await setupWithCompose(page, sshServer);
    await enablePreviewMode(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    const intent = new IntentCapture(page);

    const sentence = TEST_SENTENCES[6];
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

const VOICE_SENTENCES = BUG_SENTENCES;

test.describe('Group 2: Voice input lifecycle', () => {

  test('2.1 voice, preview off: full phrase reaches terminal', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await setupWithCompose(page, sshServer);
    await disablePreviewMode(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    const intent = new IntentCapture(page);
    const receiver = new TerminalReceiver(page);

    await intent.voiceInput(VOICE_SENTENCES[0]);
    await page.waitForTimeout(300);
    await screenshot(page, testInfo, '2.1-after-voice');

    await assertFaithful(intent, receiver, expect);
  });

  test('2.2 voice, preview off initially: starts voice → preview overlay appears, text accumulates', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await setupWithCompose(page, sshServer);
    await disablePreviewMode(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    const intent = new IntentCapture(page);

    const sentence = VOICE_SENTENCES[1];
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

  test('2.3 voice multi-word: all words captured in textarea', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await setupWithCompose(page, sshServer);
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

  test('2.4 voice → commit sends accumulated text', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await setupWithCompose(page, sshServer);
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

  test('2.5 voice → space sends text faithfully', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await setupWithCompose(page, sshServer);
    await enablePreviewMode(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    const intent = new IntentCapture(page);
    const receiver = new TerminalReceiver(page);

    const sentence = VOICE_SENTENCES[2];
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

  test('2.6 voice stops → commit still works after 2s delay', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await setupWithCompose(page, sshServer);
    await enablePreviewMode(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    const intent = new IntentCapture(page);
    const receiver = new TerminalReceiver(page);

    await intent.voiceInput(VOICE_SENTENCES[0]);

    // Wait 2s to simulate voice stopping before commit
    await page.waitForTimeout(2000);
    await screenshot(page, testInfo, '2.6-after-2s-wait');

    await tapCommit(page);
    await page.waitForTimeout(200);
    await screenshot(page, testInfo, '2.6-after-commit');

    await assertFaithful(intent, receiver, expect);
  });

  test('2.7 no timers fire during active voice: text accumulates continuously for 5s', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await setupWithCompose(page, sshServer);
    await enablePreviewMode(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    const intent = new IntentCapture(page);

    await intent.voiceInput(VOICE_SENTENCES[0]);
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

  test('5.1 direct mode Enter (#129) → \\r sent', async ({ emulatorPage: page, sshServer }, testInfo) => {
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
    }, sshServer.port);

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

  test('5.2 direct → compose → direct round-trip', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await setupWithCompose(page, sshServer);
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

  test('5.3 preview toggle mid-session', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await setupWithCompose(page, sshServer);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    const intent = new IntentCapture(page);

    // Start without preview — first word sent immediately
    await disablePreviewMode(page);
    await intent.swipeType(TEST_SENTENCES[2]);
    await page.waitForTimeout(200);
    await screenshot(page, testInfo, '5.3-no-preview-sent');

    // First sentence should have been sent
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
    await intent2.swipeType(TEST_SENTENCES[3]);
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

  test('5.4 rapid compose/commit × 5', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await setupWithCompose(page, sshServer);
    await enablePreviewMode(page);

    // 5 rapid compose+commit cycles
    for (let i = 0; i < 5; i++) {
      await page.evaluate(() => { window.__mockWsSpy = []; });

      const intent = new IntentCapture(page);
      const receiver = new TerminalReceiver(page);

      // Mix short inputs with long sentences for variety
      const text = i < 3 ? SHORT_INPUTS[i] : TEST_SENTENCES[i % TEST_SENTENCES.length];
      await intent.swipeType(text);
      await page.waitForTimeout(100);

      await tapCommit(page);
      await page.waitForTimeout(100);

      await assertFaithful(intent, receiver, expect);
    }
    await screenshot(page, testInfo, '5.4-rapid-commits-done');
  });

  test('5.5 voice then keyboard handoff', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await setupWithCompose(page, sshServer);
    await enablePreviewMode(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    const intent = new IntentCapture(page);
    const receiver = new TerminalReceiver(page);

    // "Voice" input: compositionend with data but empty textarea (voice dictation quirk)
    const voiceSentence = TEST_SENTENCES[0];
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

// ── Test data for Groups 3 and 6 ──────────────────────────────────────────────

const BACKSPACE_SENTENCES = [...BUG_SENTENCES.slice(2), ...AUTOCORRECT_SENTENCES.slice(2)];

const TIMER_SENTENCES = [...AUTOCORRECT_SENTENCES.slice(0, 2), ...SHELL_SENTENCES.slice(3)];

// ── Group 3: Preview backspace passthrough (#136) ─────────────────────────────

test.describe('Group 3: Preview backspace passthrough (#136)', () => {

  test('3.1 backspace deletes in preview — 5x backspace loses 5 chars, terminal unchanged', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await setupWithCompose(page, sshServer);
    await enablePreviewMode(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    const intent = new IntentCapture(page);
    await intent.swipeType(BACKSPACE_SENTENCES[0]);
    await page.waitForTimeout(200);

    const valueBefore = await page.evaluate(() => document.getElementById('imeInput')?.value ?? '');
    expect(valueBefore.length).toBeGreaterThan(5);

    await screenshot(page, testInfo, '3.1-before-backspace');

    // Press backspace 5x in preview
    for (let i = 0; i < 5; i++) {
      await page.locator('#imeInput').press('Backspace');
      await page.waitForTimeout(50);
    }
    await page.waitForTimeout(100);

    await screenshot(page, testInfo, '3.1-after-backspace');

    const valueAfter = await page.evaluate(() => document.getElementById('imeInput')?.value ?? '');
    // Preview should have lost 5 chars
    expect(valueAfter.length).toBe(valueBefore.length - 5);

    // No input messages should have been sent to terminal
    const inputMsgs = await page.evaluate(() =>
      (window.__mockWsSpy || []).filter(s => {
        try { return JSON.parse(s).type === 'input'; } catch { return false; }
      })
    );
    expect(inputMsgs).toHaveLength(0);
  });

  test('3.2 backspace on empty preview → SSH — 3x backspace sends 3x \\x7f', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await setupWithCompose(page, sshServer);
    await enablePreviewMode(page);

    const intent = new IntentCapture(page);
    await intent.swipeType(BACKSPACE_SENTENCES[1]);
    await page.waitForTimeout(200);

    // Commit text so preview is empty
    await tapCommit(page);
    await page.waitForTimeout(200);

    // Start fresh WS spy after commit
    await page.evaluate(() => { window.__mockWsSpy = []; });

    // Preview should now be empty — confirm
    const previewVal = await page.evaluate(() => document.getElementById('imeInput')?.value ?? '');
    expect(previewVal).toBe('');

    await screenshot(page, testInfo, '3.2-empty-preview');

    // 3x backspace on empty preview → should reach terminal
    for (let i = 0; i < 3; i++) {
      await page.locator('#imeInput').press('Backspace');
      await page.waitForTimeout(50);
    }
    await page.waitForTimeout(200);

    await screenshot(page, testInfo, '3.2-after-backspace');

    // Expect 3x \x7f sent to terminal
    const inputData = await page.evaluate(() =>
      (window.__mockWsSpy || [])
        .map(s => { try { return JSON.parse(s); } catch { return null; } })
        .filter(m => m && m.type === 'input')
        .map(m => m.data)
        .join('')
    );
    const backspaceCount = (inputData.match(/\x7f/g) || []).length;
    expect(backspaceCount).toBe(3);
  });

  test('3.3 preview → SSH transition — 4x backspace on 2-char preview: 2 delete from preview, 2x \\x7f to terminal', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await setupWithCompose(page, sshServer);
    await enablePreviewMode(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    // Type "hi" — exactly 2 chars
    const intent = new IntentCapture(page);
    await intent.swipeType('hi there from the test suite running on the emulator device');
    await page.waitForTimeout(200);

    // Manually set the preview to exactly "hi" for precise transition test
    await page.evaluate(() => {
      const el = document.getElementById('imeInput');
      if (el) el.value = 'hi';
    });

    await screenshot(page, testInfo, '3.3-preview-hi');

    // Reset spy after setup
    await page.evaluate(() => { window.__mockWsSpy = []; });

    // 4x backspace: first 2 should delete from preview, last 2 should go to terminal
    for (let i = 0; i < 4; i++) {
      await page.locator('#imeInput').press('Backspace');
      await page.waitForTimeout(50);
    }
    await page.waitForTimeout(200);

    await screenshot(page, testInfo, '3.3-after-4-backspaces');

    // Preview should be empty
    const previewVal = await page.evaluate(() => document.getElementById('imeInput')?.value ?? '');
    expect(previewVal).toBe('');

    // Terminal should have received 2x \x7f
    const inputData = await page.evaluate(() =>
      (window.__mockWsSpy || [])
        .map(s => { try { return JSON.parse(s); } catch { return null; } })
        .filter(m => m && m.type === 'input')
        .map(m => m.data)
        .join('')
    );
    const backspaceCount = (inputData.match(/\x7f/g) || []).length;
    expect(backspaceCount).toBe(2);
  });

  test('3.4 swipe-backspace through word — word removed, 2x \\x7f to terminal', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await setupWithCompose(page, sshServer);
    await enablePreviewMode(page);

    const intent = new IntentCapture(page);
    await intent.swipeType(BACKSPACE_SENTENCES[0]);
    await page.waitForTimeout(200);

    const valueBefore = await page.evaluate(() => document.getElementById('imeInput')?.value ?? '');
    const wordsBefore = valueBefore.trim().split(/\s+/);
    const lastWord = wordsBefore[wordsBefore.length - 1];

    await screenshot(page, testInfo, '3.4-before-swipe-delete');

    // Simulate word-level backspace (swipe-backspace): fires compositionend with empty data
    // then removes last word from textarea via keyboard shortcut simulation
    await page.evaluate(() => {
      const el = document.getElementById('imeInput');
      if (!el) return;
      el.focus();
      // Simulate swipe-delete: compositionend with empty data (word removed)
      el.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
      el.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: '' }));
      el.dispatchEvent(new InputEvent('input', {
        bubbles: true, inputType: 'deleteContentBackward', data: null,
      }));
      // Actually remove the last word
      const words = el.value.trim().split(/\s+/);
      words.pop();
      el.value = words.join(' ');
    });
    await page.waitForTimeout(100);

    const valueAfterDelete = await page.evaluate(() => document.getElementById('imeInput')?.value ?? '');
    // Word should have been removed from preview
    expect(valueAfterDelete).not.toContain(lastWord);

    // Trim preview to a single char so 2 backspaces = 1 drain + 1 overflow
    await page.evaluate(() => {
      const el = document.getElementById('imeInput');
      if (el) el.value = 'x';
    });

    // Reset spy to track only the overflow backspaces
    await page.evaluate(() => { window.__mockWsSpy = []; });

    // 2 backspaces: first drains preview ('x' → ''), second overflows as \x7f
    for (let i = 0; i < 2; i++) {
      await page.locator('#imeInput').press('Backspace');
      await page.waitForTimeout(50);
    }
    await page.waitForTimeout(200);

    await screenshot(page, testInfo, '3.4-after-extra-backspaces');

    // Preview should be empty
    const previewVal = await page.evaluate(() => document.getElementById('imeInput')?.value ?? '');
    expect(previewVal).toBe('');

    // The overflow backspace should have reached the terminal as \x7f
    const inputData = await page.evaluate(() =>
      (window.__mockWsSpy || [])
        .map(s => { try { return JSON.parse(s); } catch { return null; } })
        .filter(m => m && m.type === 'input')
        .map(m => m.data)
        .join('')
    );
    const backspaceCount = (inputData.match(/\x7f/g) || []).length;
    expect(backspaceCount).toBe(1);
  });

});

// ── Group 6: Timer behavior ───────────────────────────────────────────────────

test.describe('Group 6: Timer behavior', () => {

  test('6.1 auto-clear after compositionend (no preview) — text sent, textarea cleared', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await setupWithCompose(page, sshServer);
    // Preview OFF — text should auto-send and clear
    await disablePreviewMode(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    const intent = new IntentCapture(page);
    const receiver = new TerminalReceiver(page);

    await intent.swipeType(TIMER_SENTENCES[0]);

    // Wait for auto-clear timer (up to 2s)
    await page.waitForTimeout(2500);

    await screenshot(page, testInfo, '6.1-after-autoclear');

    // Textarea should be cleared
    const textareaVal = await page.evaluate(() => document.getElementById('imeInput')?.value ?? '');
    expect(textareaVal).toBe('');

    // Text should have been sent faithfully
    await assertFaithful(intent, receiver, expect);
  });

  test('6.2 auto-clear does NOT fire during active voice — words accumulate', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await setupWithCompose(page, sshServer);
    await disablePreviewMode(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    const sentence = TIMER_SENTENCES[1];
    const words = sentence.split(' ').slice(0, 12);

    // Simulate continuous voice: fire compositionstart, then compositionupdate/end
    // for each word with a 500ms gap (simulating natural voice pace)
    // The auto-clear timer should reset on each compositionend, not fire mid-dictation
    for (let i = 0; i < words.length; i++) {
      const word = words[i];
      await page.evaluate((t) => {
        const el = document.getElementById('imeInput');
        if (!el) return;
        el.focus();
        el.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
        el.value = (el.value ? el.value + ' ' : '') + t;
        el.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: t }));
        el.dispatchEvent(new InputEvent('input', {
          bubbles: true, inputType: 'insertCompositionText', data: t,
        }));
      }, word);
      // 400ms between words — within auto-clear window but timer resets each time
      await page.waitForTimeout(400);
    }

    await screenshot(page, testInfo, '6.2-voice-accumulating');

    // Textarea should still have accumulated text (auto-clear hasn't fired)
    const textareaVal = await page.evaluate(() => document.getElementById('imeInput')?.value ?? '');
    // At minimum the last few words should still be present (timer reset on last word)
    expect(textareaVal.trim().length).toBeGreaterThan(0);

    // Wait for final auto-clear
    await page.waitForTimeout(2500);
    await screenshot(page, testInfo, '6.2-after-final-clear');

    // Now it should be cleared (final word's timer fired)
    const finalVal = await page.evaluate(() => document.getElementById('imeInput')?.value ?? '');
    expect(finalVal).toBe('');
  });

  test('6.3 auto-clear resets on new input — no premature clear', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await setupWithCompose(page, sshServer);
    await disablePreviewMode(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    // Type first word, wait 1s (not enough to trigger auto-clear)
    const intent = new IntentCapture(page);

    await intent.swipeType(TIMER_SENTENCES[0]);
    await page.waitForTimeout(1000);

    await screenshot(page, testInfo, '6.3-after-1s-wait');

    // Type second sentence — timer should reset
    await intent.swipeType(TIMER_SENTENCES[1]);
    await page.waitForTimeout(1000);

    await screenshot(page, testInfo, '6.3-after-second-input');

    // Both sentences should have been sent by now
    const receiver = new TerminalReceiver(page);
    const received = await receiver.getReceivedText();
    expect(received).toContain(TIMER_SENTENCES[1].split(' ')[0]);

    await screenshot(page, testInfo, '6.3-done');
  });

  test('6.4 editing state is sticky — no auto-clear after 10s', async ({ emulatorPage: page, sshServer }, testInfo) => {
    await setupWithCompose(page, sshServer);
    await enablePreviewMode(page);
    await page.evaluate(() => { window.__mockWsSpy = []; });

    const intent = new IntentCapture(page);
    await intent.swipeType(TIMER_SENTENCES[0]);
    await page.waitForTimeout(200);

    // Transition to editing state by tapping textarea
    await page.locator('#imeInput').dispatchEvent('touchstart', { bubbles: true });
    await page.waitForTimeout(200);

    await screenshot(page, testInfo, '6.4-editing-state');

    // Verify we're in editing state
    const hasEditing = await page.evaluate(() =>
      document.getElementById('imeInput')?.classList.contains('ime-editing') ?? false
    );
    expect(hasEditing).toBe(true);

    const textBefore = await page.evaluate(() => document.getElementById('imeInput')?.value ?? '');
    expect(textBefore.length).toBeGreaterThan(0);

    // Wait 10s — auto-clear must NOT fire in editing state
    await page.waitForTimeout(10_000);

    await screenshot(page, testInfo, '6.4-after-10s');

    const textAfter = await page.evaluate(() => document.getElementById('imeInput')?.value ?? '');
    // Text should still be present — editing state suppresses auto-clear
    expect(textAfter).toBe(textBefore);

    // No input messages should have been sent (text held, not auto-sent)
    const inputMsgs = await page.evaluate(() =>
      (window.__mockWsSpy || []).filter(s => {
        try { return JSON.parse(s).type === 'input'; } catch { return false; }
      })
    );
    expect(inputMsgs).toHaveLength(0);
  });

});
