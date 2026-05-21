/**
 * Unit tests for the gesture-window diagnostic telemetry (#502).
 *
 * Scope: passive observation only. Verifies that
 *   - touchstart on #terminal opens a gesture window
 *   - focusin on .xterm-helper-textarea during the window logs
 *     `gesture_focusin` with isHelper:true and a non-empty stack
 *   - visualViewport.resize during the window logs `gesture_viewport_resize`
 *     with the correct deltaH
 *   - at window close, anomaly conditions trigger uploadGestureAnomaly()
 *   - the gesture-upload throttle (10 min) prevents a second upload within
 *     the window
 *
 * These tests do NOT exercise focus mutation. They only assert that the
 * diagnostic listeners capture what they're supposed to capture.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { JSDOM } from 'jsdom';

// ── Test DOM bootstrap ───────────────────────────────────────────────────────

function buildDom(): JSDOM {
  // Minimal DOM: just the terminal element + a helper textarea (mimicking
  // xterm.js's hidden helper) and our imeInput. The gesture-window code reads
  // `document.activeElement`, queries for `.xterm-helper-textarea`, and binds
  // to `document` + `window.visualViewport`.
  const html = `<!doctype html><html><body>
    <div id="terminal"></div>
    <button id="handleCopyBtn" class="hidden"></button>
    <textarea id="imeInput"></textarea>
    <textarea class="xterm-helper-textarea"></textarea>
  </body></html>`;
  return new JSDOM(html, { url: 'http://localhost:8081/', pretendToBeVisual: true });
}

let dom: JSDOM;
let storage: Map<string, string>;
const performanceNow = { value: 0 };

beforeEach(() => {
  dom = buildDom();
  vi.stubGlobal('document', dom.window.document);
  vi.stubGlobal('window', dom.window);
  vi.stubGlobal('navigator', dom.window.navigator);
  vi.stubGlobal('location', dom.window.location);
  vi.stubGlobal('fetch', vi.fn(() => Promise.resolve({ ok: true })));
  // JSDOM-provided constructors that the diagnostic code uses via
  // `instanceof Element` and so on. Vitest's node env doesn't supply these.
  vi.stubGlobal('Element', dom.window.Element);
  vi.stubGlobal('HTMLElement', dom.window.HTMLElement);
  vi.stubGlobal('HTMLTextAreaElement', dom.window.HTMLTextAreaElement);
  vi.stubGlobal('FocusEvent', dom.window.FocusEvent);
  vi.stubGlobal('Event', dom.window.Event);

  // visualViewport: jsdom doesn't supply one. Build a fake with
  // dispatch hooks the gesture-window listener can subscribe to.
  const vvListeners = new Set<EventListenerOrEventListenerObject>();
  const fakeVV = {
    height: 800,
    width: 400,
    scale: 1,
    offsetTop: 0,
    addEventListener: (type: string, listener: EventListenerOrEventListenerObject) => {
      if (type === 'resize') vvListeners.add(listener);
    },
    removeEventListener: (type: string, listener: EventListenerOrEventListenerObject) => {
      if (type === 'resize') vvListeners.delete(listener);
    },
    /** Test hook — fire a synthetic resize. */
    __fire(newHeight: number): void {
      this.height = newHeight;
      for (const l of vvListeners) {
        try {
          if (typeof l === 'function') l(new dom.window.Event('resize'));
          else (l as EventListenerObject).handleEvent(new dom.window.Event('resize'));
        } catch { /* */ }
      }
    },
  };
  Object.defineProperty(dom.window, 'visualViewport', {
    configurable: true,
    get: () => fakeVV,
  });
  vi.stubGlobal('visualViewport', fakeVV);

  // performance.now() — deterministic clock for delta assertions.
  performanceNow.value = 0;
  vi.stubGlobal('performance', {
    now: () => performanceNow.value,
  });

  // localStorage backing the throttle key.
  storage = new Map<string, string>();
  vi.stubGlobal('localStorage', {
    getItem: (k: string) => storage.get(k) ?? null,
    setItem: (k: string, v: string) => { storage.set(k, v); },
    removeItem: (k: string) => { storage.delete(k); },
    clear: () => { storage.clear(); },
    length: 0,
    key: () => null,
  });

  vi.resetModules();
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.useRealTimers();
});

// ── Helpers ──────────────────────────────────────────────────────────────────

/** Step the fake performance clock forward. */
function advanceTime(ms: number): void {
  performanceNow.value += ms;
}

/** Dispatch a synthetic focusin from the given element so it bubbles up
 *  through the real DOM tree to capturing listeners on document. JSDOM
 *  ignores a manually-set `target` on a fresh Event, so we dispatch directly
 *  from the desired source. */
function fireFocusInOn(el: Element): void {
  el.dispatchEvent(new dom.window.FocusEvent('focusin', { bubbles: true }));
}

/** Dispatch a synthetic focusout via the element so it bubbles to document. */
function fireFocusOutOn(el: Element): void {
  el.dispatchEvent(new dom.window.FocusEvent('focusout', { bubbles: true }));
}

/** Build a gesture-log reader fresh from the just-imported module. */
async function loadModulesFresh(): Promise<{
  gestureLog: typeof import('../gesture-log.js');
  selection: typeof import('../selection.js');
  dropTelemetry: typeof import('../drop-telemetry.js');
}> {
  // Stub the modules selection.ts depends on but doesn't need for these tests.
  // ime.js: must export getIMEState; provide a minimal stub.
  vi.doMock('../ime.js', () => ({
    getIMEState: () => 'idle',
  }));
  vi.doMock('../state.js', () => ({
    currentSession: () => null,
  }));
  vi.doMock('../ui.js', () => ({
    toast: () => { /* */ },
    focusIME: () => { /* */ },
  }));
  vi.doMock('../terminal.js', () => ({
    getKeyboardVisible: () => false,
  }));
  vi.doMock('../ime-fixup.js', () => ({
    reconstructFromBuffer: () => '',
  }));

  const gestureLog = await import('../gesture-log.js');
  gestureLog.clearGestureLog();
  const selection = await import('../selection.js');
  const dropTelemetry = await import('../drop-telemetry.js');
  return { gestureLog, selection, dropTelemetry };
}

// ── Tests ────────────────────────────────────────────────────────────────────

describe('gesture-window telemetry (#502)', () => {
  it('logs gesture_focusin with isHelper:true and a non-empty stack', async () => {
    const { gestureLog, selection } = await loadModulesFresh();

    selection._testOpenGestureWindow();

    advanceTime(120);
    const helper = dom.window.document.querySelector('.xterm-helper-textarea');
    expect(helper).toBeTruthy();
    fireFocusInOn(helper!);

    const log = gestureLog.getGestureLog();
    const focusin = log.find((e) => e.e === 'gesture_focusin');
    expect(focusin, 'gesture_focusin should be logged').toBeTruthy();
    const d = focusin!.d as Record<string, unknown>;
    expect(d.isHelper).toBe(true);
    expect(d.t).toBe(120);
    expect(typeof d.stack === 'string' && (d.stack as string).length > 0).toBe(true);
    expect(d.targetClass).toContain('xterm-helper-textarea');
  });

  it('logs gesture_viewport_resize with correct deltaH', async () => {
    const { gestureLog, selection } = await loadModulesFresh();

    selection._testOpenGestureWindow();
    advanceTime(50);
    // Synthetic resize from 800 → 430 (370px shrink, matching the bug trace).
    const vv = (dom.window as unknown as { visualViewport: { __fire: (h: number) => void } }).visualViewport;
    vv.__fire(430);

    const log = gestureLog.getGestureLog();
    const resize = log.find((e) => e.e === 'gesture_viewport_resize');
    expect(resize, 'gesture_viewport_resize should be logged').toBeTruthy();
    const d = resize!.d as Record<string, unknown>;
    expect(d.h).toBe(430);
    expect(d.deltaH).toBe(-370);
    expect(d.t).toBe(50);
  });

  it('triggers uploadGestureAnomaly when helper textarea gains focus during window', async () => {
    const { gestureLog, selection } = await loadModulesFresh();

    selection._testOpenGestureWindow();
    advanceTime(60);
    fireFocusInOn(dom.window.document.querySelector('.xterm-helper-textarea')!);

    // Close the gesture window — this is what evaluates anomaly conditions.
    selection._testCloseGestureWindow();

    // The anomaly_uploaded log entry tells us whether upload fired.
    const log = gestureLog.getGestureLog();
    const uploaded = log.find((e) => e.e === 'gesture_anomaly_uploaded');
    expect(uploaded, 'gesture_anomaly_uploaded must be logged when helper focuses during gesture').toBeTruthy();
    const d = uploaded!.d as Record<string, unknown>;
    expect(d.status).toBe('sent');
    expect(d.reason).toBe('focus_during_long_press');

    // And the upload itself must hit the gesture-telemetry endpoint.
    const fetchSpy = (globalThis as unknown as { fetch: ReturnType<typeof vi.fn> }).fetch;
    expect(fetchSpy).toHaveBeenCalled();
    const calls = fetchSpy.mock.calls;
    const url = calls[0]?.[0];
    expect(url).toBe('api/gesture-telemetry');
  });

  it('throttles a second upload within 10 minutes', async () => {
    const { gestureLog, selection } = await loadModulesFresh();

    // First gesture — fires anomaly.
    selection._testOpenGestureWindow();
    advanceTime(60);
    fireFocusInOn(dom.window.document.querySelector('.xterm-helper-textarea')!);
    selection._testCloseGestureWindow();

    const fetchSpy = (globalThis as unknown as { fetch: ReturnType<typeof vi.fn> }).fetch;
    expect(fetchSpy).toHaveBeenCalledTimes(1);

    // Second gesture — within 10min throttle window. Should NOT upload again.
    selection._testOpenGestureWindow();
    advanceTime(60);
    fireFocusInOn(dom.window.document.querySelector('.xterm-helper-textarea')!);
    selection._testCloseGestureWindow();

    // Only the first call should have hit fetch.
    expect(fetchSpy).toHaveBeenCalledTimes(1);

    // But the second anomaly should still be logged as "throttled".
    const log = gestureLog.getGestureLog();
    const uploads = log.filter((e) => e.e === 'gesture_anomaly_uploaded');
    expect(uploads.length).toBeGreaterThanOrEqual(2);
    const throttled = uploads.find((u) => (u.d as Record<string, unknown>).status === 'throttled');
    expect(throttled, 'second upload within window must be logged as throttled').toBeTruthy();
  });

  it('does NOT trigger an anomaly when only #imeInput receives focus', async () => {
    const { gestureLog, selection } = await loadModulesFresh();

    selection._testOpenGestureWindow();
    advanceTime(30);
    fireFocusInOn(dom.window.document.getElementById('imeInput')!);
    selection._testCloseGestureWindow();

    // gesture_focusin should be logged, but isHelper:false, and no
    // gesture_anomaly_uploaded with status:sent should appear.
    const log = gestureLog.getGestureLog();
    const focusin = log.find((e) => e.e === 'gesture_focusin');
    expect(focusin).toBeTruthy();
    expect((focusin!.d as Record<string, unknown>).isHelper).toBe(false);
    expect((focusin!.d as Record<string, unknown>).isOurs).toBe(true);

    const uploaded = log.find(
      (e) => e.e === 'gesture_anomaly_uploaded' &&
             (e.d as Record<string, unknown>).status === 'sent',
    );
    expect(uploaded).toBeUndefined();

    const fetchSpy = (globalThis as unknown as { fetch: ReturnType<typeof vi.fn> }).fetch;
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it('logs focusout events during the window too', async () => {
    const { gestureLog, selection } = await loadModulesFresh();

    selection._testOpenGestureWindow();
    advanceTime(10);
    fireFocusOutOn(dom.window.document.getElementById('imeInput')!);

    const log = gestureLog.getGestureLog();
    const focusout = log.find((e) => e.e === 'gesture_focusout');
    expect(focusout).toBeTruthy();
    expect((focusout!.d as Record<string, unknown>).targetId).toBe('imeInput');
  });

  it('logs an initial gesture_helper_focus_audit at gesture window open', async () => {
    const { gestureLog, selection } = await loadModulesFresh();

    selection._testOpenGestureWindow();

    const log = gestureLog.getGestureLog();
    const audit = log.find((e) => e.e === 'gesture_helper_focus_audit');
    expect(audit, 'initial audit snapshot should be logged on window open').toBeTruthy();
    const d = audit!.d as Record<string, unknown>;
    expect(d.trigger).toBe('touchstart');
    expect(d.helperPresent).toBe(true);
  });

  it('stops capturing focus events after the window closes', async () => {
    const { gestureLog, selection } = await loadModulesFresh();

    selection._testOpenGestureWindow();
    selection._testCloseGestureWindow();

    // Clear any logs from the open phase.
    gestureLog.clearGestureLog();

    // Fire a focusin AFTER window closed — must NOT be logged.
    fireFocusInOn(dom.window.document.querySelector('.xterm-helper-textarea')!);

    const log = gestureLog.getGestureLog();
    const focusin = log.find((e) => e.e === 'gesture_focusin');
    expect(focusin, 'focusin outside the gesture window must not be logged').toBeUndefined();
  });
});
