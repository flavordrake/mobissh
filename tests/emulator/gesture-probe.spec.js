/**
 * tests/emulator/gesture-probe.spec.js
 *
 * Touch event delivery smoke tests — KEEP as permanent regression guard.
 *
 * Uses a minimal standalone HTML page (public/gesture-probe.html) and
 * progressively adds complexity layers to verify that ADB swipe events
 * reach the DOM at each pipeline stage. Run these whenever touch behavior
 * changes: new gesture handlers, CSS changes on #terminal, or xterm.js
 * upgrades that may register their own touch handlers.
 *
 * Key finding these tests encode: `touch-action: none` on the target
 * element is REQUIRED for Chrome Android to deliver ADB swipe events to
 * JavaScript. Without it, Chrome's compositor consumes the swipe as a
 * native scroll gesture and JS never sees touchstart/touchmove/touchend.
 *
 * IMPORTANT: All event listeners must be injected via page.evaluate(),
 * NOT relied upon from inline <script> tags. CDP context isolation on
 * Android Chrome means page-script globals are invisible to evaluate().
 *
 * Run: npx playwright test --config=playwright.emulator.config.js tests/emulator/gesture-probe.spec.js
 */

const { test: base, expect } = require('@playwright/test');
const { chromium } = require('@playwright/test');
const { execSync } = require('child_process');

const CDP_PORT = Number(process.env.CDP_PORT || 9222);
const BASE_URL = (process.env.BASE_URL || 'http://localhost:8081').replace(/\/?$/, '/');

function ensureAdbForward() {
  try {
    const existing = execSync('adb forward --list', { encoding: 'utf8' });
    if (existing.includes(`tcp:${CDP_PORT}`)) return;
  } catch { /* not forwarded yet */ }
  execSync(`adb forward tcp:${CDP_PORT} localabstract:chrome_devtools_remote`, {
    encoding: 'utf8', timeout: 5000,
  });
}

function adbSwipe(x1, y1, x2, y2, durationMs = 300) {
  execSync(`adb shell input swipe ${x1} ${y1} ${x2} ${y2} ${durationMs}`);
}

function adbTap(x, y) {
  execSync(`adb shell input tap ${x} ${y}`);
}

function dismissKeyboard() {
  execSync('adb shell input keyevent KEYCODE_BACK');
}

async function screenshot(page, testInfo, name) {
  const buf = await page.screenshot({ fullPage: false });
  await testInfo.attach(name, { body: buf, contentType: 'image/png' });
}

/**
 * Inject touch event listeners via page.evaluate and return a collector function.
 * This is the ONLY reliable way to capture events on Android Chrome via CDP.
 * Inline <script> globals are invisible due to context isolation.
 */
async function injectListeners(page, { touchAction = null, passive = true, preventDefault = false } = {}) {
  await page.evaluate(({ touchAction, passive, preventDefault }) => {
    window.__injectedEvents = [];
    const el = document.getElementById('target') || document.body;
    if (touchAction) el.style.touchAction = touchAction;

    const log = (type, e) => {
      if (preventDefault && e.cancelable) e.preventDefault();
      const touch = e.touches[0] || e.changedTouches[0];
      window.__injectedEvents.push({
        type,
        clientX: touch ? Math.round(touch.clientX) : null,
        clientY: touch ? Math.round(touch.clientY) : null,
        screenX: touch ? Math.round(touch.screenX) : null,
        screenY: touch ? Math.round(touch.screenY) : null,
        touches: e.touches.length,
        cancelable: e.cancelable,
        defaultPrevented: e.defaultPrevented,
        ts: Date.now()
      });
    };

    el.addEventListener('touchstart', e => log('start', e), { passive, capture: true });
    el.addEventListener('touchmove', e => log('move', e), { passive, capture: true });
    el.addEventListener('touchend', e => log('end', e), { capture: true });
  }, { touchAction, passive, preventDefault });
}

async function collectEvents(page) {
  return page.evaluate(() => {
    const events = window.__injectedEvents || [];
    window.__injectedEvents = [];
    return events;
  });
}

function formatReport(header, events) {
  return [
    header,
    `Events received: ${events.length}`,
    ...events.map(e => {
      const parts = [`  ${e.type}`];
      parts.push(`client=(${e.clientX},${e.clientY})`);
      if (e.screenX != null) parts.push(`screen=(${e.screenX},${e.screenY})`);
      parts.push(`touches=${e.touches}`);
      if (e.cancelable !== undefined) parts.push(`cancelable=${e.cancelable}`);
      if (e.defaultPrevented !== undefined) parts.push(`prevented=${e.defaultPrevented}`);
      return parts.join(' ');
    }),
  ].join('\n');
}

const test = base.extend({
  // eslint-disable-next-line no-empty-pattern
  cdpBrowser: [async ({}, use) => {
    ensureAdbForward();
    const browser = await chromium.connectOverCDP(`http://127.0.0.1:${CDP_PORT}`, {
      timeout: 10_000,
    });
    await use(browser);
    browser.close();
  }, { scope: 'worker' }],

  probePage: async ({ cdpBrowser }, use) => {
    const context = cdpBrowser.contexts()[0];
    const page = await context.newPage();

    try {
      const nagBtn = page.locator('button:has-text("No thanks"), button:has-text("No, thanks"), button:has-text("Not now"), button:has-text("Skip"), [id*="negative"], [id*="dismiss"]');
      await nagBtn.first().click({ timeout: 2000 });
    } catch { /* no nag modal */ }

    await page.goto(BASE_URL + 'gesture-probe.html', { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#target', { timeout: 10_000 });
    await page.waitForTimeout(500);

    // Prime ADB touch pipeline (cold-start: first swipes may not deliver events)
    adbSwipe(540, 800, 540, 1400, 300);
    adbSwipe(540, 1400, 540, 800, 300);
    await page.waitForTimeout(500);

    await use(page);
    await page.close().catch(() => {});
  },
});

test.describe('Gesture probe: ADB delivery pipeline', () => {

  test('L0 — bare div: ADB tap delivers events, swipe does NOT (no touch-action:none)', async ({ probePage: page }, testInfo) => {
    // L0 baseline: default CSS (no touch-action:none)
    // Expected: ADB tap delivers events (Chrome doesn't intercept taps)
    //           ADB swipe gets 0 events (Chrome's compositor handles it as native scroll)
    await injectListeners(page);
    await screenshot(page, testInfo, '01-page-loaded');

    // ADB tap
    adbTap(540, 1200);
    await page.waitForTimeout(500);
    const tapEvents = await collectEvents(page);

    // ADB swipe (1000ms, full-screen)
    adbSwipe(540, 600, 540, 1800, 1000);
    await page.waitForTimeout(1200);
    const swipeEvents = await collectEvents(page);

    await screenshot(page, testInfo, '02-after-gestures');

    await testInfo.attach('L0-report', {
      body: Buffer.from([
        formatReport('ADB TAP (540, 1200):', tapEvents),
        '',
        formatReport('ADB SWIPE (540,600)→(540,1800) 1000ms:', swipeEvents),
        '',
        tapEvents.length > 0 && swipeEvents.length === 0
          ? 'EXPECTED: tap works but swipe consumed by Chrome compositor (no touch-action:none)'
          : tapEvents.length > 0 && swipeEvents.length > 0
          ? 'UNEXPECTED: swipe works without touch-action:none'
          : 'UNEXPECTED: tap also fails — check ADB connectivity'
      ].join('\n')),
      contentType: 'text/plain',
    });

    // Tap should work (ADB taps always reach Chrome DOM)
    expect(tapEvents.filter(e => e.type === 'start').length,
      'ADB tap must produce at least one touchstart').toBeGreaterThan(0);
    // Swipe is expected to fail without touch-action:none — this IS the finding.
    // Don't assert swipe success here; L1 tests with touch-action:none.
  });

  test('L1 — touch-action:none: ADB swipe delivers events', async ({ probePage: page }, testInfo) => {
    // L1: add touch-action:none — this is the key CSS property
    await injectListeners(page, { touchAction: 'none' });
    await screenshot(page, testInfo, '01-touch-action-none-set');

    adbSwipe(540, 600, 540, 1800, 1000);
    await page.waitForTimeout(1200);

    const events = await collectEvents(page);
    await screenshot(page, testInfo, '02-after-swipe');

    await testInfo.attach('L1-report', {
      body: Buffer.from(formatReport('L1: touch-action:none, swipe (540,600)→(540,1800) 1000ms', events)),
      contentType: 'text/plain',
    });

    const moves = events.filter(e => e.type === 'move');
    expect(moves.length, 'L1: touch-action:none MUST enable ADB swipe delivery').toBeGreaterThan(0);
  });

  test('L2 — passive:false + preventDefault: ADB swipe still works', async ({ probePage: page }, testInfo) => {
    // L2: touch-action:none + passive:false + preventDefault (mimics our app's handler)
    await injectListeners(page, { touchAction: 'none', passive: false, preventDefault: true });
    await screenshot(page, testInfo, '01-passive-false-set');

    adbSwipe(540, 600, 540, 1800, 1000);
    await page.waitForTimeout(1200);

    const events = await collectEvents(page);
    await screenshot(page, testInfo, '02-after-swipe');

    await testInfo.attach('L2-report', {
      body: Buffer.from(formatReport('L2: passive:false + preventDefault, swipe (540,600)→(540,1800) 1000ms', events)),
      contentType: 'text/plain',
    });

    const moves = events.filter(e => e.type === 'move');
    expect(moves.length, 'L2: passive:false + preventDefault must not kill ADB swipe').toBeGreaterThan(0);
  });

  test('L6 — full MobiSSH app: instrument #terminal chain, ADB swipe delivery', async ({ cdpBrowser }, testInfo) => {
    const context = cdpBrowser.contexts()[0];
    const page = await context.newPage();

    try {
      const nagBtn = page.locator('button:has-text("No thanks"), button:has-text("No, thanks"), button:has-text("Not now"), button:has-text("Skip"), [id*="negative"], [id*="dismiss"]');
      await nagBtn.first().click({ timeout: 2000 });
    } catch { /* no nag modal */ }

    await page.goto(BASE_URL, { waitUntil: 'domcontentloaded' });
    await page.evaluate(() => localStorage.clear());
    await page.reload({ waitUntil: 'domcontentloaded' });

    const modalAppeared = await page.locator('#vaultSetupOverlay:not(.hidden)')
      .waitFor({ state: 'visible', timeout: 10_000 })
      .then(() => true).catch(() => false);

    if (modalAppeared) {
      await page.locator('#vaultNewPw').fill('test');
      await page.locator('#vaultConfirmPw').fill('test');
      await page.evaluate(() => {
        const cb = document.getElementById('vaultEnableBio');
        if (cb) cb.checked = false;
      });
      dismissKeyboard();
      await page.waitForTimeout(300);
      await page.evaluate(() => document.getElementById('vaultSetupCreate')?.click());
      await page.locator('#vaultSetupOverlay').waitFor({ state: 'hidden', timeout: 5000 });
    }

    await page.locator('[data-panel="terminal"]').click();
    await page.waitForSelector('.xterm-screen', { timeout: 30_000 });
    dismissKeyboard();
    await page.waitForTimeout(500);

    // Step 1: Map every element from #terminal down, with computed touch-action
    const domChain = await page.evaluate(() => {
      const results = [];
      function walk(el, depth) {
        const cs = getComputedStyle(el);
        results.push({
          depth,
          tag: el.tagName,
          id: el.id || '',
          cls: (el.className?.toString() || '').substring(0, 60),
          touchAction: cs.touchAction,
          pointerEvents: cs.pointerEvents,
          overflow: cs.overflow,
          rect: el.getBoundingClientRect(),
        });
        for (const child of el.children) walk(child, depth + 1);
      }
      const terminal = document.getElementById('terminal');
      if (terminal) walk(terminal, 0);
      return results;
    });

    // Step 2: What element is at the touch target coordinates?
    const hitTarget = await page.evaluate(() => {
      // Check several points along the swipe path (viewport coords)
      const points = [
        { x: 270, y: 300 },
        { x: 270, y: 600 },
        { x: 270, y: 900 },
      ];
      return points.map(p => {
        const el = document.elementFromPoint(p.x, p.y);
        if (!el) return { x: p.x, y: p.y, tag: 'null' };
        return {
          x: p.x, y: p.y,
          tag: el.tagName,
          id: el.id,
          cls: (el.className?.toString() || '').substring(0, 40),
          touchAction: getComputedStyle(el).touchAction,
        };
      });
    });

    // Step 3: Attach listeners at EVERY level in the chain
    await page.evaluate(() => {
      window.__chainEvents = {};
      function addListeners(el, label) {
        window.__chainEvents[label] = [];
        const log = (type, e) => {
          window.__chainEvents[label].push({
            type,
            target: e.target?.tagName + (e.target?.id ? '#' + e.target.id : '') + (e.target?.className ? '.' + e.target.className.toString().split(' ')[0] : ''),
          });
        };
        el.addEventListener('touchstart', e => log('start', e), { capture: true });
        el.addEventListener('touchmove', e => log('move', e), { capture: true });
        el.addEventListener('touchend', e => log('end', e), { capture: true });
      }

      addListeners(window, 'window');
      addListeners(document, 'document');
      addListeners(document.body, 'body');

      const terminal = document.getElementById('terminal');
      if (terminal) addListeners(terminal, '#terminal');

      const xterm = terminal?.querySelector('.xterm');
      if (xterm) addListeners(xterm, '.xterm');

      const screen = terminal?.querySelector('.xterm-screen');
      if (screen) addListeners(screen, '.xterm-screen');

      const canvases = terminal?.querySelectorAll('canvas');
      if (canvases) {
        canvases.forEach((c, i) => addListeners(c, `canvas[${i}]`));
      }

      const helpers = terminal?.querySelector('.xterm-helper-textarea');
      if (helpers) addListeners(helpers, '.xterm-helper-textarea');
    });

    await screenshot(page, testInfo, '01-instrumented');

    // Step 4: ADB swipe
    adbSwipe(540, 600, 540, 1800, 1000);
    await page.waitForTimeout(1500);

    const chainEvents = await page.evaluate(() => window.__chainEvents);
    await screenshot(page, testInfo, '02-after-swipe');

    // Build report
    const lines = [
      'DOM chain from #terminal:',
      ...domChain.map(e => {
        const indent = '  '.repeat(e.depth);
        const r = e.rect;
        return `${indent}${e.tag}${e.id ? '#' + e.id : ''}${e.cls ? '.' + e.cls.split(' ')[0] : ''} touch-action=${e.touchAction} pointer-events=${e.pointerEvents} rect=(${Math.round(r.left)},${Math.round(r.top)},${Math.round(r.width)}x${Math.round(r.height)})`;
      }),
      '',
      'Hit targets (elementFromPoint):',
      ...hitTarget.map(h => `  (${h.x},${h.y}) => ${h.tag}${h.id ? '#' + h.id : ''}${h.cls ? '.' + h.cls : ''} touch-action=${h.touchAction}`),
      '',
      'ADB swipe (540,600 -> 540,1800, 1000ms) events per level:',
      ...Object.entries(chainEvents).map(([label, events]) => {
        const starts = events.filter(e => e.type === 'start').length;
        const moves = events.filter(e => e.type === 'move').length;
        const ends = events.filter(e => e.type === 'end').length;
        const targets = [...new Set(events.map(e => e.target))];
        return `  ${label}: start=${starts} move=${moves} end=${ends} targets=[${targets.join(', ')}]`;
      }),
    ];

    const report = lines.join('\n');
    console.log(report);
    await testInfo.attach('L6-chain-report', {
      body: Buffer.from(report), contentType: 'text/plain',
    });

    const windowMoves = (chainEvents['window'] || []).filter(e => e.type === 'move').length;
    expect(windowMoves,
      'ADB swipe must produce touchmove events at window capture level'
    ).toBeGreaterThan(0);

    await page.close().catch(() => {});
  });
});
