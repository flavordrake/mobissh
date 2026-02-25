/**
 * playwright.emulator.config.js
 *
 * Config for running tests against real Chrome on the Android emulator.
 * Connects via CDP (Chrome DevTools Protocol) over ADB-forwarded port.
 *
 * Prerequisites:
 *   1. Emulator running: bash ~/Android/Sdk/launch-mobissh-avd.sh
 *   2. MobiSSH server running on port 8081
 *   3. ADB reverse: adb reverse tcp:8081 tcp:8081
 *
 * Usage:
 *   npx playwright test --config=playwright.emulator.config.js
 *   npm run test:emulator
 */

const { defineConfig } = require('@playwright/test');

const BASE_URL = (process.env.BASE_URL || 'http://localhost:8081').replace(/\/?$/, '/');
const useExternalServer = !!process.env.BASE_URL;

module.exports = defineConfig({
  testDir: './tests/emulator',
  timeout: 60_000,
  retries: 0,

  reporter: [
    ['line'],
    ['html', { open: 'never', outputFolder: 'playwright-report-emulator' }],
  ],

  // Start MobiSSH server unless BASE_URL is provided
  webServer: useExternalServer ? undefined : {
    command: 'node server/index.js',
    port: 8081,
    reuseExistingServer: true,
    timeout: 15_000,
    env: { PORT: '8081' },
  },

  // No browser launch — tests connect over CDP via the emulatorPage fixture
  projects: [
    {
      name: 'android-emulator',
      use: {
        baseURL: BASE_URL,
        screenshot: 'on',
        trace: 'retain-on-failure',
      },
    },
  ],
});
