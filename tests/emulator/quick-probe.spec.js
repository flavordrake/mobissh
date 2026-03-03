/**
 * tests/emulator/quick-probe.spec.js
 *
 * Minimal smoke test: confirms touch-action:none is the key to ADB swipe
 * event delivery. This test proved the root cause — Chrome's compositor
 * consumes ADB swipe as native scroll unless touch-action:none is set.
 * Keep as a permanent canary for touch pipeline regressions.
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
  } catch {}
  execSync(`adb forward tcp:${CDP_PORT} localabstract:chrome_devtools_remote`, { encoding: 'utf8', timeout: 5000 });
}

const test = base.extend({
  // eslint-disable-next-line no-empty-pattern
  cdpBrowser: [async ({}, use) => {
    ensureAdbForward();
    const browser = await chromium.connectOverCDP(`http://127.0.0.1:${CDP_PORT}`, { timeout: 10_000 });
    await use(browser);
    browser.close();
  }, { scope: 'worker' }],
});

test('ADB swipe with passive:false + touch-action:none delivers events', async ({ cdpBrowser }, testInfo) => {
  const ctx = cdpBrowser.contexts()[0];
  const page = await ctx.newPage();

  try {
    const nagBtn = page.locator('button:has-text("No thanks"), button:has-text("No, thanks"), button:has-text("Not now"), button:has-text("Skip"), [id*="negative"], [id*="dismiss"]');
    await nagBtn.first().click({ timeout: 2000 });
  } catch {}

  await page.goto(BASE_URL + 'gesture-probe.html', { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#target', { timeout: 10000 });
  await page.waitForTimeout(500);

  const buf1 = await page.screenshot();
  await testInfo.attach('01-page-loaded', { body: buf1, contentType: 'image/png' });

  // Test 1: passive doc listeners (baseline - expected to get 0 swipe events)
  await page.evaluate(() => {
    window.__passiveEvents = [];
    document.addEventListener('touchstart', e => {
      window.__passiveEvents.push({ type: 'start' });
    }, { capture: true, passive: true });
    document.addEventListener('touchmove', e => {
      window.__passiveEvents.push({ type: 'move' });
    }, { capture: true, passive: true });
    document.addEventListener('touchend', e => {
      window.__passiveEvents.push({ type: 'end' });
    }, { capture: true, passive: true });
  });

  // Test 2: passive:false element listeners + touch-action:none
  await page.evaluate(() => {
    window.__nonPassiveEvents = [];
    const el = document.getElementById('target');
    el.style.touchAction = 'none';
    el.addEventListener('touchstart', e => {
      e.preventDefault();
      window.__nonPassiveEvents.push({ type: 'start' });
    }, { passive: false });
    el.addEventListener('touchmove', e => {
      e.preventDefault();
      window.__nonPassiveEvents.push({ type: 'move' });
    }, { passive: false });
    el.addEventListener('touchend', e => {
      window.__nonPassiveEvents.push({ type: 'end' });
    }, { passive: false });
  });

  // ADB swipe
  execSync('adb shell input swipe 540 600 540 1800 1000');
  await page.waitForTimeout(1500);

  const results = await page.evaluate(() => ({
    passive: (window.__passiveEvents || []).slice(0),
    nonPassive: (window.__nonPassiveEvents || []).slice(0),
  }));

  const buf2 = await page.screenshot();
  await testInfo.attach('02-after-swipe', { body: buf2, contentType: 'image/png' });

  const report = [
    'ADB SWIPE (540,600) to (540,1800) 1000ms:',
    '',
    'Passive doc capture listeners:',
    '  events: ' + results.passive.length,
    '  types: ' + results.passive.map(e => e.type).join(','),
    '',
    'Non-passive element listeners (touch-action:none + preventDefault):',
    '  events: ' + results.nonPassive.length,
    '  types: ' + results.nonPassive.map(e => e.type).join(','),
    '',
    results.nonPassive.length > 0 && results.passive.length === 0
      ? 'CONFIRMED: Chrome only dispatches ADB swipe to non-passive listeners on touch-action:none element'
      : results.nonPassive.length > 0 && results.passive.length > 0
      ? 'Both receive events (passive doesnt matter, touch-action:none is the key)'
      : results.nonPassive.length === 0
      ? 'NEITHER received events (something else is blocking)'
      : 'UNEXPECTED',
  ].join('\n');

  console.log(report);
  await testInfo.attach('hypothesis-report', {
    body: Buffer.from(report), contentType: 'text/plain',
  });

  expect(results.nonPassive.length, 'Non-passive listeners must receive ADB swipe').toBeGreaterThan(0);

  await page.close().catch(() => {});
});
