/**
 * tests/appium/smoke.spec.js
 *
 * Basic Appium smoke test — verifies the Appium + UiAutomator2 + Chrome
 * pipeline is working end-to-end. This is the "does anything work at all" test.
 */

const { test, expect } = require('./fixtures');

test.describe('Appium smoke', () => {

  test('connects to Chrome and loads the app', async ({ driver }) => {
    // driver fixture already navigated to BASE_URL and switched to WEBVIEW
    const title = await driver.getTitle();
    expect(title).toContain('MobiSSH');
  });

  test('can read DOM via executeScript', async ({ driver }) => {
    const heading = await driver.executeScript(
      'return document.querySelector("h1, .app-title, #terminal")?.tagName || "NOT_FOUND"',
      []
    );
    // We expect either a terminal div or some heading element
    expect(heading).not.toBe('NOT_FOUND');
  });

  test('can read localStorage', async ({ driver }) => {
    // Write and read back
    await driver.executeScript(
      'localStorage.setItem("appium_smoke_test", "hello")', []
    );
    const value = await driver.executeScript(
      'return localStorage.getItem("appium_smoke_test")', []
    );
    expect(value).toBe('hello');

    // Cleanup
    await driver.executeScript(
      'localStorage.removeItem("appium_smoke_test")', []
    );
  });

  test('can list available contexts', async ({ driver, appium }) => {
    // Switch to native to enumerate contexts
    await appium.switchToNative(driver);
    const contexts = await driver.getContexts();
    console.log('Available contexts:', JSON.stringify(contexts));

    // Should have at least NATIVE_APP and a WEBVIEW
    expect(contexts).toContain('NATIVE_APP');
    const hasWebview = contexts.some(c => c.startsWith('WEBVIEW') || c.startsWith('CHROMIUM'));
    expect(hasWebview).toBe(true);

    // Switch back to webview
    await appium.switchToWebview(driver);
  });

  test('can perform a tap gesture via Appium', async ({ driver, appium }) => {
    // Inject a tap listener
    await driver.executeScript(`
      window.__appiumTapCount = 0;
      document.addEventListener('click', () => window.__appiumTapCount++);
    `, []);

    // Switch to native for gesture, then back
    await appium.switchToNative(driver);

    // Tap the center of the screen using W3C Actions
    await driver.performActions([{
      type: 'pointer',
      id: 'finger1',
      parameters: { pointerType: 'touch' },
      actions: [
        { type: 'pointerMove', duration: 0, x: 540, y: 1200, origin: 'viewport' },
        { type: 'pointerDown', button: 0 },
        { type: 'pause', duration: 100 },
        { type: 'pointerUp', button: 0 },
      ],
    }]);
    await driver.releaseActions();
    await driver.pause(500);

    await appium.switchToWebview(driver);

    const tapCount = await driver.executeScript(
      'return window.__appiumTapCount || 0', []
    );
    console.log(`Tap count: ${tapCount}`);
    expect(tapCount).toBeGreaterThan(0);
  });

});
