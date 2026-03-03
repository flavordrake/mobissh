/**
 * tests/appium/integrate-145-settings-layout.spec.js
 *
 * Integration test for issue #145: settings layout restructure.
 * Debug overlay and pinch-to-zoom move to "Advanced" section.
 * Separate clear-data/clear-cache buttons merged into single "Reset app".
 *
 * BEFORE merge: no .advanced-section, #clearDataBtn and #clearCacheBtn exist → tests FAIL.
 * AFTER merge: .advanced-section exists, #resetAppBtn replaces old buttons → tests PASS.
 */

const { test, expect, setupVault } = require('./fixtures');

test.describe('Issue #145: settings layout restructure', () => {

  test('Advanced section exists with correct title', async ({ driver }) => {
    await setupVault(driver);

    await driver.executeScript(
      "document.querySelector('[data-panel=\"settings\"]')?.click()", []);
    await driver.pause(1000);

    const advancedExists = await driver.executeScript(
      "return !!document.querySelector('.advanced-section')", []);
    expect(advancedExists).toBe(true);

    const titleText = await driver.executeScript(`
      const el = document.querySelector('.advanced-section-title');
      return el ? el.textContent.trim() : null;
    `, []);
    expect(titleText).toBeTruthy();
    expect(titleText.toLowerCase()).toContain('advanced');
  });

  test('debug overlay and pinch-to-zoom are in Advanced section', async ({ driver }) => {
    await setupVault(driver);

    await driver.executeScript(
      "document.querySelector('[data-panel=\"settings\"]')?.click()", []);
    await driver.pause(1000);

    // #debugOverlay should be inside .advanced-section, not .danger-zone
    const debugInAdvanced = await driver.executeScript(`
      const section = document.querySelector('.advanced-section');
      return section ? !!section.querySelector('#debugOverlay') : false;
    `, []);
    expect(debugInAdvanced).toBe(true);

    const pinchInAdvanced = await driver.executeScript(`
      const section = document.querySelector('.advanced-section');
      return section ? !!section.querySelector('#enablePinchZoom') : false;
    `, []);
    expect(pinchInAdvanced).toBe(true);
  });

  test('single Reset button replaces old clear buttons', async ({ driver }) => {
    await setupVault(driver);

    await driver.executeScript(
      "document.querySelector('[data-panel=\"settings\"]')?.click()", []);
    await driver.pause(1000);

    const resetExists = await driver.executeScript(
      "return !!document.getElementById('resetAppBtn')", []);
    expect(resetExists).toBe(true);

    const clearDataGone = await driver.executeScript(
      "return !document.getElementById('clearDataBtn')", []);
    expect(clearDataGone).toBe(true);

    const clearCacheGone = await driver.executeScript(
      "return !document.getElementById('clearCacheBtn')", []);
    expect(clearCacheGone).toBe(true);
  });

});
