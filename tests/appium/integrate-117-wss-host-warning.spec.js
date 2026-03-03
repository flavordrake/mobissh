/**
 * tests/appium/integrate-117-wss-host-warning.spec.js
 *
 * Integration test for issue #117: warn when WSS host differs from page origin.
 *
 * BEFORE merge: #wsWarnHostMismatch element does not exist in DOM → tests FAIL.
 * AFTER merge: element exists, shows/hides based on URL host match → tests PASS.
 */

const { test, expect, setupVault, BASE_URL } = require('./fixtures');

test.describe('Issue #117: WSS host mismatch warning', () => {

  test('warning element exists in settings DOM', async ({ driver }) => {
    await setupVault(driver);

    // Navigate to settings panel
    await driver.executeScript(
      "document.querySelector('[data-panel=\"settings\"]')?.click()", []);
    await driver.pause(1000);

    const exists = await driver.executeScript(
      "return !!document.getElementById('wsWarnHostMismatch')", []);
    expect(exists).toBe(true);
  });

  test('warning appears when WSS host differs from page origin', async ({ driver }) => {
    await setupVault(driver);

    await driver.executeScript(
      "document.querySelector('[data-panel=\"settings\"]')?.click()", []);
    await driver.pause(1000);

    // Set WSS URL to a different host
    await driver.executeScript(`
      const input = document.getElementById('wsUrl');
      if (input) {
        input.value = 'wss://different-host.example.com:8080';
        input.dispatchEvent(new Event('input', { bubbles: true }));
      }
    `, []);
    await driver.pause(500);

    // Warning should be visible (not hidden)
    const isHidden = await driver.executeScript(`
      const el = document.getElementById('wsWarnHostMismatch');
      return el ? el.classList.contains('hidden') : true;
    `, []);
    expect(isHidden).toBe(false);
  });

  test('warning hides when WSS host matches page origin', async ({ driver }) => {
    await setupVault(driver);

    await driver.executeScript(
      "document.querySelector('[data-panel=\"settings\"]')?.click()", []);
    await driver.pause(1000);

    // First trigger the warning with a mismatched host
    await driver.executeScript(`
      const input = document.getElementById('wsUrl');
      if (input) {
        input.value = 'wss://different-host.example.com:8080';
        input.dispatchEvent(new Event('input', { bubbles: true }));
      }
    `, []);
    await driver.pause(300);

    // Now set to matching host (same as page origin)
    const matchingUrl = BASE_URL.replace(/^http/, 'ws').replace(/\/$/, '');
    await driver.executeScript(`
      const input = document.getElementById('wsUrl');
      if (input) {
        input.value = arguments[0];
        input.dispatchEvent(new Event('input', { bubbles: true }));
      }
    `, [matchingUrl]);
    await driver.pause(500);

    const isHidden = await driver.executeScript(`
      const el = document.getElementById('wsWarnHostMismatch');
      return el ? el.classList.contains('hidden') : true;
    `, []);
    expect(isHidden).toBe(true);
  });

});
