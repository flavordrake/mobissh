// playwright.config.js
// Local emulated-browser tests: Pixel 7, iPhone 14, Desktop Chrome.
// Run with: npx playwright test
// For BrowserStack real-device testing: npm run test:browserstack

// eslint-disable-next-line @typescript-eslint/no-var-requires
const { defineConfig, devices } = require('@playwright/test');

// BASE_URL controls where tests run:
//
//   npx playwright test
//     Direct localhost — fastest, no auth needed. Default for CI and dev.
//
//   BASE_URL=https://raserver.tailbe5094.ts.net/ssh npx playwright test
//     Through nginx reverse proxy — matches the real user experience.
//     Requires: nginx /ssh location pointing at localhost:8081 (see nginx-ssh-location.conf)
//     Requires: MobiSSH started with  BASE_PATH=/ssh PORT=8081 node server/index.js
//     No code-server auth needed — nginx /ssh bypasses code-server entirely.
//
const BASE_URL = (process.env.BASE_URL || 'http://localhost:8081').replace(/\/?$/, '/');
const useExternalServer = !!process.env.BASE_URL;

module.exports = defineConfig({
  testDir: './tests',
  timeout: 30_000,
  // One retry on CI to tolerate transient xterm.js canvas init timing
  retries: process.env.CI ? 1 : 0,
  workers: process.env.CI ? 2 : undefined,
  reporter: [
    ['list'],
    ['html', { open: 'never', outputFolder: 'playwright-report' }],
  ],

  // Start the MobiSSH server before tests; reuse if already running locally.
  // Skipped when BASE_URL is set — the external server is already up.
  webServer: useExternalServer ? undefined : {
    command: 'node server/index.js',
    port: 8081,
    reuseExistingServer: !process.env.CI,
    timeout: 15_000,
    env: {
      PORT: '8081',
    },
  },

  use: {
    baseURL: BASE_URL,
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    // Disable service worker for tests so we always get fresh responses
    serviceWorkers: 'block',
  },

  projects: [
    // ── Android Chrome emulation (Pixel 7) ──────────────────────────────────
    {
      name: 'pixel-7',
      use: {
        ...devices['Pixel 7'],
        // Pixel 7 device descriptor provides:
        //   viewport: { width: 412, height: 915 }
        //   userAgent: Android Chrome UA string
        //   hasTouch: true, isMobile: true
        //   defaultBrowserType: 'chromium'
      },
    },

    // ── iOS Safari emulation (iPhone 14) ────────────────────────────────────
    {
      name: 'iphone-14',
      use: {
        ...devices['iPhone 14'],
      },
    },

    // ── Desktop Chrome (sanity / regression baseline) ───────────────────────
    {
      name: 'chromium',
      use: {
        ...devices['Desktop Chrome'],
      },
    },
  ],
});
