/**
 * tests/appium/integrate-145-settings-layout.spec.js
 *
 * Integration test for issue #145: settings layout restructure.
 * Debug overlay in "Advanced" collapsible section, pinch-to-zoom in "Gestures".
 * Separate clear-data/clear-cache buttons merged into single "Reset app".
 *
 * Settings panel uses <details class="settings-section"> collapsible sections.
 */

const { test, expect, setupVault } = require('./fixtures');

/** Find a <details class="settings-section"> by its <summary> text. */
function findSection(name) {
  return `
    const sections = document.querySelectorAll('details.settings-section');
    for (const s of sections) {
      const sum = s.querySelector('summary');
      if (sum && sum.textContent.trim().toLowerCase() === '${name.toLowerCase()}') return s;
    }
    return null;
  `;
}

test.describe('Issue #145: settings layout restructure', () => {

  test('Advanced section exists with correct title', async ({ driver }) => {
    await setupVault(driver);

    await driver.executeScript(
      "document.querySelector('[data-panel=\"settings\"]')?.click()", []);
    await driver.pause(1000);

    const advancedExists = await driver.executeScript(
      `${findSection('Advanced')} return !!s || false;`.replace('return s;', 'var s2 = s; return !!s2;'),
      []);
    // Simpler check:
    const exists = await driver.executeScript(`
      const sections = document.querySelectorAll('details.settings-section');
      for (const s of sections) {
        const sum = s.querySelector('summary');
        if (sum && sum.textContent.trim() === 'Advanced') return true;
      }
      return false;
    `, []);
    expect(exists).toBe(true);
  });

  test('debug overlay is in Advanced section, pinch-to-zoom is in Gestures', async ({ driver }) => {
    await setupVault(driver);

    await driver.executeScript(
      "document.querySelector('[data-panel=\"settings\"]')?.click()", []);
    await driver.pause(1000);

    const debugInAdvanced = await driver.executeScript(`
      const sections = document.querySelectorAll('details.settings-section');
      for (const s of sections) {
        const sum = s.querySelector('summary');
        if (sum && sum.textContent.trim() === 'Advanced') return !!s.querySelector('#debugOverlay');
      }
      return false;
    `, []);
    expect(debugInAdvanced).toBe(true);

    const pinchInGestures = await driver.executeScript(`
      const sections = document.querySelectorAll('details.settings-section');
      for (const s of sections) {
        const sum = s.querySelector('summary');
        if (sum && sum.textContent.trim() === 'Gestures') return !!s.querySelector('#enablePinchZoom');
      }
      return false;
    `, []);
    expect(pinchInGestures).toBe(true);
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
