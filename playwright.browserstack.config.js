// playwright.browserstack.config.js
// Real-device BrowserStack Automate config.
// Run with: npm run test:browserstack
// Requires BROWSERSTACK_USERNAME and BROWSERSTACK_ACCESS_KEY env vars.
// The browserstack-node-sdk intercepts browser launches and routes them
// to BrowserStack's cloud, using browserstack.yml for device selection.

const { defineConfig } = require('@playwright/test');

module.exports = defineConfig({
  testDir: './tests',
  // Only run files prefixed with "browserstack-" — local tests (layout, ime)
  // use fixtures that require ports not tunnelled by BrowserStack Local.
  testMatch: ['**/browserstack-*.spec.js'],
  timeout: 60_000,
  retries: 1,
  workers: 5,
  reporter: [
    ['list'],
    ['html', { open: 'never', outputFolder: 'playwright-report-bs' }],
  ],

  // BrowserStack Local tunnel proxies the WS server back to cloud devices.
  // The tunnel is started by the GitHub Actions workflow (or `browserstack-node-sdk`
  // with browserstackLocal: true in browserstack.yml).
  use: {
    baseURL: 'http://localhost:8081',
    trace: 'on',
    screenshot: 'on',
    video: 'on',
  },

  // browserstack-node-sdk overrides these projects with the devices listed
  // in browserstack.yml — this file only needs one placeholder project.
  projects: [
    {
      name: 'bs-placeholder',
      use: {},
    },
  ],
});
