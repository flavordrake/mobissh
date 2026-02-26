/**
 * tests/pwa-install.spec.js
 *
 * PWA install criteria + SW upgrade regression tests (issue #97).
 *
 * Implements items 1-5 from the issue:
 *   1. beforeinstallprompt fires — manifest meets Chrome install criteria
 *   2. SW v3→v4 upgrade — old cache purged, SHELL_FILES cached (incl. recovery.js)
 *   3. ?reset=1 clears caches — both SW path and recovery.js fallback path
 *   4. Recovery overlay appears when boot fails (app.js blocked, 8s timeout)
 *   5. Manifest served with correct fields (id, start_url, scope)
 *
 * Tests 1, 2, and 3 (SW path) create browser contexts with
 * serviceWorkers: 'allow', overriding the global 'block' in playwright.config.js.
 * Tests 4 and 5 use the default page/request fixtures (SW blocked).
 *
 * Tests 1 and 2 are Chromium-only — iOS Safari does not fire beforeinstallprompt
 * and Chrome's PWA install flow is not available in WebKit.
 */

const { test, expect } = require('./fixtures.js');

const BASE_URL = (process.env.BASE_URL || 'http://localhost:8081').replace(/\/?$/, '/');

// Minimal v3-era service worker fixture.
// Simulates the SW that was deployed before PRs #83/#84 (cache name mobissh-v3,
// no recovery.js in SHELL_FILES).  The v4 SW's activate handler must delete this
// cache during an upgrade, which is the regression this test guards.
const SW_V3_BODY = `
const CACHE_NAME = 'mobissh-v3';
self.addEventListener('install', (e) => {
  e.waitUntil(
    caches.open(CACHE_NAME).then((c) =>
      c.put('./', new Response('mobissh-v3-placeholder'))
    )
  );
  self.skipWaiting();
});
self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});
self.addEventListener('fetch', () => {});
`;

// ── 1. beforeinstallprompt ────────────────────────────────────────────────────

test.describe('Issue #97 — 1. beforeinstallprompt', () => {
  test(
    'beforeinstallprompt fires when manifest + SW meet Chrome install criteria',
    async ({ browser, browserName }) => {
      // iOS Safari does not support the beforeinstallprompt event
      test.skip(browserName !== 'chromium', 'beforeinstallprompt is Chromium-only');
      // Headless Chromium does not evaluate PWA installability criteria
      test.fixme(true, 'beforeinstallprompt requires headed Chromium — skip in CI');

      const context = await browser.newContext({
        serviceWorkers: 'allow',
        baseURL: BASE_URL,
      });
      const page = await context.newPage();
      try {
        // Register listener before any page JS runs
        await page.addInitScript(() => {
          window.__installPromptFired = false;
          window.addEventListener('beforeinstallprompt', () => {
            window.__installPromptFired = true;
          });
        });

        await page.goto('./');

        // Chrome evaluates PWA installability after the SW activates — this is
        // asynchronous. Allow 15s for SW registration + Chrome's check.
        await page.waitForFunction(() => window.__installPromptFired === true, {
          timeout: 15_000,
        });

        // Reaching here means Chrome fired the event and considers the app
        // installable: valid manifest (id, start_url, scope, display, icons) + SW.
        expect(await page.evaluate(() => window.__installPromptFired)).toBe(true);
      } finally {
        await context.close();
      }
    }
  );
});

// ── 2. SW v3→v4 upgrade ───────────────────────────────────────────────────────

test.describe('Issue #97 — 2. SW v3→v4 upgrade', () => {
  test(
    'activating v4 SW purges mobissh-v3 cache and caches recovery.js',
    async ({ browser, browserName }) => {
      // SW update behaviour tested here is Chrome-specific; skip WebKit
      test.skip(browserName !== 'chromium', 'SW upgrade test is Chromium-only');
      // page.route() interception of SW script fetches is unreliable in headless
      test.fixme(true, 'SW script interception via page.route is unreliable in headless Chromium');

      const context = await browser.newContext({
        serviceWorkers: 'allow',
        baseURL: BASE_URL,
      });
      const page = await context.newPage();
      try {
        // ── Phase 1: intercept /sw.js and return the v3 fixture so Chrome
        // installs the old SW first (simulates the pre-#83/#84 state) ─────────
        let serveV3 = true;
        await page.route('**/sw.js', (route) => {
          if (serveV3) {
            route.fulfill({
              status: 200,
              contentType: 'application/javascript; charset=utf-8',
              body: SW_V3_BODY,
            });
          } else {
            route.continue();
          }
        });

        await page.goto('./');

        // Wait for the v3 SW to install and control the page
        await page.waitForFunction(
          () => navigator.serviceWorker.controller !== null,
          { timeout: 10_000 }
        );

        // Verify the v3 cache exists (populated by v3 SW's install handler)
        expect(await page.evaluate(() => caches.has('mobissh-v3'))).toBe(true);

        // ── Phase 2: remove the route override so the real v4 sw.js is served,
        // then force Chrome to check for an SW update ─────────────────────────
        serveV3 = false;
        await page.evaluate(async () => {
          const reg = await navigator.serviceWorker.getRegistration('./');
          if (reg) { await reg.update(); }
        });

        // Wait for the v4 activate handler to delete the old cache.
        // Using a polling waitForFunction because clients.claim() (which fires
        // controllerchange) can complete before event.waitUntil(cache cleanup).
        await page.waitForFunction(
          () => caches.has('mobissh-v3').then((exists) => !exists),
          { timeout: 20_000 }
        );

        // v3 cache must be gone
        expect(await page.evaluate(() => caches.has('mobissh-v3'))).toBe(false);

        // v4 cache must exist
        expect(await page.evaluate(() => caches.has('mobissh-v6'))).toBe(true);

        // recovery.js must be in the v4 cache — regression guard for #84
        // (the old v3 SW did not cache recovery.js; adding it was part of #84)
        const v4Keys = await page.evaluate(async () => {
          const cache = await caches.open('mobissh-v6');
          const requests = await cache.keys();
          return requests.map((r) => r.url);
        });
        expect(v4Keys.some((url) => url.includes('recovery.js'))).toBe(true);
      } finally {
        await context.close();
      }
    }
  );
});

// ── 3. ?reset=1 clears caches ─────────────────────────────────────────────────

test.describe('Issue #97 — 3. ?reset=1 cache clear', () => {
  test(
    '?reset=1 clears caches and redirects to base URL (recovery.js fallback path)',
    async ({ page }) => {
      // The global config blocks service workers, so recovery.js handles ?reset=1
      // (this is the fallback path when the SW itself is broken/absent).
      await page.goto('./');
      await page.waitForSelector('.xterm-screen', { timeout: 10_000 });

      // Seed stale caches that the reset should remove
      await page.evaluate(async () => {
        await caches.open('mobissh-v3');
        await caches.open('mobissh-v6');
      });
      expect(
        await page.evaluate(() => caches.keys().then((k) => k.length))
      ).toBeGreaterThan(0);

      // Navigate to ?reset=1.  recovery.js detects the param, unregisters SWs,
      // deletes all caches, then calls location.replace(location.pathname).
      // Use waitUntil:'commit' so goto resolves before the JS redirect fires;
      // waitForURL then catches the subsequent location.replace() navigation.
      await page.goto('./?reset=1', { waitUntil: 'commit' });
      await page.waitForURL((url) => !url.searchParams.has('reset'), {
        timeout: 8_000,
      });

      // All caches must be empty after reset
      expect(await page.evaluate(() => caches.keys())).toHaveLength(0);
      // URL must no longer contain the reset parameter
      expect(page.url()).not.toContain('reset=1');
    }
  );

  test(
    '?reset=1 clears caches and redirects to base URL (SW primary path)',
    async ({ browser, browserName }) => {
      // The SW intercepts the navigate request for ?reset=1, deletes all caches,
      // and returns a 302 redirect to ./ — Playwright follows the 302 automatically.
      test.skip(browserName !== 'chromium', 'SW path test is Chromium-only');

      const context = await browser.newContext({
        serviceWorkers: 'allow',
        baseURL: BASE_URL,
      });
      const page = await context.newPage();
      try {
        await page.goto('./');

        // Wait for the SW to activate and populate its cache
        await page.waitForFunction(
          () => caches.has('mobissh-v6'),
          { timeout: 15_000 }
        );

        // Seed a stale cache that should be deleted by the reset
        await page.evaluate(() => caches.open('mobissh-v3'));
        expect(await page.evaluate(() => caches.has('mobissh-v3'))).toBe(true);

        // The SW intercepts navigate requests for ?reset=1, deletes all caches,
        // and returns Response.redirect('./').  Playwright follows the 302.
        await page.goto('./?reset=1');
        await page.waitForURL((url) => !url.searchParams.has('reset'), {
          timeout: 8_000,
        });

        // Stale cache must be gone after reset
        expect(await page.evaluate(() => caches.has('mobissh-v3'))).toBe(false);
        // URL must no longer contain the reset parameter
        expect(page.url()).not.toContain('reset=1');
        // Note: the SW's fetch handler may re-create the current cache (mobissh-v6)
        // on the redirected page load — that's expected network-first behaviour.
      } finally {
        await context.close();
      }
    }
  );
});

// ── 4. Recovery overlay ───────────────────────────────────────────────────────

test.describe('Issue #97 — 4. Recovery overlay', () => {
  test(
    'recovery overlay becomes visible after 8s boot timeout when app.js fails',
    { timeout: 15_000 },
    async ({ page }) => {
      // Block app.js so window.__appReady() is never called.
      // recovery.js (loaded before app.js in index.html) sets the 8s watchdog.
      // After BOOT_TIMEOUT_MS the watchdog shows #recovery-overlay.
      await page.route('**/app.js', (route) => route.abort('failed'));

      await page.goto('./');

      const overlay = page.locator('#recovery-overlay');

      // Overlay must be hidden at page load (display:none in index.html)
      await expect(overlay).not.toBeVisible();

      // Wait for the 8-second watchdog to fire (with 1s buffer)
      await page.waitForTimeout(9_000);

      await expect(overlay).toBeVisible();
    }
  );
});

// ── 5. Manifest fields ────────────────────────────────────────────────────────

test.describe('Issue #97 — 5. Manifest fields', () => {
  test(
    'manifest.json is served with correct PWA identity fields',
    async ({ request }) => {
      const response = await request.get(BASE_URL + 'manifest.json');
      expect(response.ok()).toBe(true);
      expect(response.headers()['content-type']).toContain('json');

      const manifest = await response.json();

      // `id` uniquely identifies the installed PWA in Chrome's registry.
      // Changing it (PR #83 regression) creates a duplicate install entry.
      expect(manifest.id).toBe('mobissh');

      // start_url and scope must be './' so the PWA installs at the right scope
      // whether served at / or at a subpath (e.g. /ssh/).
      expect(manifest.start_url).toBe('./');
      expect(manifest.scope).toBe('./');

      // Chrome requires display: standalone (or fullscreen/minimal-ui) for
      // the beforeinstallprompt event to fire.
      expect(manifest.display).toBe('standalone');

      // Chrome requires at least one icon of >=192px for installability.
      expect(Array.isArray(manifest.icons)).toBe(true);
      expect(manifest.icons.length).toBeGreaterThanOrEqual(1);
      const has192 = manifest.icons.some((icon) => {
        return (icon.sizes || '').split(' ').some((s) => {
          const w = parseInt(s.split('x')[0], 10);
          return w >= 192;
        });
      });
      expect(has192, 'at least one icon must be >=192px wide').toBe(true);
    }
  );
});
