/**
 * tests/appium/integrate-123-password-detection.spec.js
 *
 * Integration test for issue #123: suppress keyboard suggestions on password prompts.
 * When the terminal shows a "Password:" prompt, the IME textarea's autocomplete
 * attribute changes to "new-password" to suppress Android keyboard suggestions.
 *
 * BEFORE merge: _checkPasswordPrompt() doesn't exist, autocomplete stays 'off' → tests FAIL.
 * AFTER merge: autocomplete changes to 'new-password' on password lines → tests PASS.
 */

const { test, expect, setupVault, setupRealSSHConnection, sendCommand,
  exposeTerminal, dismissKeyboardViaBack } = require('./fixtures');

test.describe('Issue #123: password prompt keyboard suppression', () => {

  test('autocomplete changes to new-password on password prompt', async ({ driver, sshServer }) => {
    await setupVault(driver);
    await setupRealSSHConnection(driver);
    await exposeTerminal(driver);

    // Baseline: autocomplete should be 'off' (no password prompt)
    const initialAc = await driver.executeScript(
      "return document.getElementById('imeInput')?.getAttribute('autocomplete')", []);
    expect(initialAc).toBe('off');

    // Create a password prompt by running `read -sp "Password: "`
    // This displays "Password: " at the cursor line and waits for input
    await sendCommand(driver, 'read -sp "Password: "');
    await driver.pause(2000);

    // Focus the IME input to trigger the password detection check
    await driver.executeScript(`
      const el = document.getElementById('imeInput');
      if (el) { el.blur(); }
    `, []);
    await driver.pause(300);
    await driver.executeScript(`
      const el = document.getElementById('imeInput');
      if (el) { el.focus(); }
    `, []);
    await driver.pause(1000);

    const ac = await driver.executeScript(
      "return document.getElementById('imeInput')?.getAttribute('autocomplete')", []);
    expect(ac).toBe('new-password');
  });

  test('autocomplete resets to off after submitting password', async ({ driver, sshServer }) => {
    await setupVault(driver);
    await setupRealSSHConnection(driver);
    await exposeTerminal(driver);

    // Trigger password prompt
    await sendCommand(driver, 'read -sp "Password: "');
    await driver.pause(2000);

    // Focus to trigger detection
    await driver.executeScript("document.getElementById('imeInput')?.focus()", []);
    await driver.pause(1000);

    // Verify it detected the password prompt
    const acBefore = await driver.executeScript(
      "return document.getElementById('imeInput')?.getAttribute('autocomplete')", []);
    expect(acBefore).toBe('new-password');

    // Send Enter to submit the password (ends the `read` command)
    await driver.executeScript(`
      const el = document.getElementById('imeInput');
      if (el) {
        el.value = '\\n';
        el.dispatchEvent(new InputEvent('input', { bubbles: true, data: '\\n' }));
        el.value = '';
      }
    `, []);
    await driver.pause(1500);

    const acAfter = await driver.executeScript(
      "return document.getElementById('imeInput')?.getAttribute('autocomplete')", []);
    expect(acAfter).toBe('off');
  });

});
