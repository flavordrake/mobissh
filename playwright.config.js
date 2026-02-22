// playwright.config.js
// Local emulated-browser tests: Pixel 7, iPhone 14, Desktop Chrome.
// Run with: npx playwright test
// For BrowserStack real-device testing: npm run test:browserstack

// eslint-disable-next-line @typescript-eslint/no-var-requires
const { defineConfig, devices } = require('@playwright/test');

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
  webServer: {
    command: 'node server/index.js',
    port: 8080,
    reuseExistingServer: !process.env.CI,
    timeout: 15_000,
    env: {
      // Disable nodemon-style restarts; plain node is enough
      PORT: '8080',
    },
  },

  use: {
    baseURL: 'http://localhost:8080',
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
