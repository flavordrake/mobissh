/**
 * playwright.appium.config.js
 *
 * Config for running Appium-based tests against Chrome on the Android emulator.
 * Playwright is ONLY the test runner here — no browser launch, no CDP.
 * All device interaction goes through WebDriverIO → Appium → UiAutomator2.
 *
 * Prerequisites:
 *   1. Emulator running with Chrome
 *   2. Appium server running: ./scripts/start-appium.sh
 *   3. MobiSSH server running: scripts/server-ctl.sh ensure
 *   4. ADB reverse: adb reverse tcp:8081 tcp:8081
 *
 * Usage:
 *   npx playwright test --config=playwright.appium.config.js
 */

const { defineConfig } = require('@playwright/test');

const BASE_URL = (process.env.BASE_URL || 'http://localhost:8081').replace(/\/?$/, '/');
const useExternalServer = !!process.env.BASE_URL;

module.exports = defineConfig({
  testDir: './tests/appium',
  outputDir: './test-results-appium',  // separate from default test-results/ to avoid cleanup
  timeout: 120_000,  // Appium sessions are slower (HTTP → server → device)
  retries: 0,
  workers: 1,  // single emulator, single Chrome — no parallelism

  reporter: [
    ['list', { printSteps: true }],
    ['html', { open: 'never', outputFolder: 'playwright-report-appium' }],
  ],

  webServer: useExternalServer ? undefined : {
    command: 'node server/index.js',
    port: 8081,
    reuseExistingServer: true,
    timeout: 15_000,
    env: { PORT: '8081' },
  },

  projects: [
    {
      name: 'appium-android',
      use: {
        baseURL: BASE_URL,
        actionTimeout: 30_000,
      },
    },
  ],
});
