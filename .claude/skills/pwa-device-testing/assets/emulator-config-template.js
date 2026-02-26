/**
 * playwright.emulator.config.js — Template
 *
 * Playwright config for testing against real Chrome on an Android emulator.
 * Connects via CDP (Chrome DevTools Protocol) over ADB-forwarded port.
 *
 * Adapt BASE_URL, port, and webServer command for your project.
 *
 * Prerequisites:
 *   1. Emulator running with Chrome open
 *   2. Chrome marked debuggable: adb shell am set-debug-app --persistent com.android.chrome
 *   3. CDP forwarded: adb forward tcp:9222 localabstract:chrome_devtools_remote
 *   4. App server running on the port below
 *   5. Reverse forwarded: adb reverse tcp:<port> tcp:<port>
 */

const { defineConfig } = require('@playwright/test');

// --- Adapt these for your project ---
const SERVER_PORT = 8081;
const SERVER_CMD = `node server/index.js`;
// -------------------------------------

const BASE_URL = (process.env.BASE_URL || `http://localhost:${SERVER_PORT}`).replace(/\/?$/, '/');
const useExternalServer = !!process.env.BASE_URL;

module.exports = defineConfig({
  testDir: './tests/emulator',
  timeout: 60_000,
  retries: 0,
  workers: 1, // REQUIRED: single Chrome instance via CDP — parallel workers destabilise pages

  reporter: [
    // Phase 1 (bootstrapping): use list with printSteps for maximum visibility
    ['list', { printSteps: true }],
    // Phase 3 (maintenance): switch to ['line'] for compact output
    ['html', { open: 'never', outputFolder: 'playwright-report-emulator' }],
  ],

  // Start app server unless BASE_URL is provided externally
  webServer: useExternalServer ? undefined : {
    command: SERVER_CMD,
    port: SERVER_PORT,
    reuseExistingServer: true,
    timeout: 15_000,
    env: { PORT: String(SERVER_PORT) },
  },

  // No browser launch — tests connect over CDP via emulatorPage fixture
  projects: [
    {
      name: 'android-emulator',
      use: {
        baseURL: BASE_URL,
        screenshot: 'on',
        trace: 'retain-on-failure',
        actionTimeout: 10_000, // fail fast on bad selectors instead of waiting full test timeout
      },
    },
  ],
});
