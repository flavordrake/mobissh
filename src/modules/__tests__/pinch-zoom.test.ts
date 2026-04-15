import { describe, it, expect, beforeEach } from 'vitest';

/**
 * Tests for pinch-zoom controller (#456).
 *
 * The controller manages scale/tx/ty state for a target element inside a viewport.
 * Pinch gestures zoom; single-finger gestures pan (only when zoomed).
 *
 * vitest/JSDOM does not support real TouchEvent dispatch, so these tests focus on
 * structural invariants: initial state, bounds clamping, reset, destroy idempotency,
 * and pinch math verified through a testable seam.
 */

import { attachPinchZoom } from '../pinch-zoom.js';

/**
 * Build a minimal element pair that exposes just enough surface for the controller.
 * We use a lightweight stub rather than JSDOM to keep these tests fast and isolated.
 */
interface StubListener {
  type: string;
  handler: EventListenerOrEventListenerObject;
  options?: AddEventListenerOptions | boolean;
}

interface StubElement {
  style: Record<string, string>;
  _listeners: StubListener[];
  addEventListener(
    type: string,
    handler: EventListenerOrEventListenerObject,
    options?: AddEventListenerOptions | boolean
  ): void;
  removeEventListener(
    type: string,
    handler: EventListenerOrEventListenerObject,
    options?: AddEventListenerOptions | boolean
  ): void;
  getBoundingClientRect(): { left: number; top: number; width: number; height: number; right: number; bottom: number };
  clientWidth: number;
  clientHeight: number;
  offsetWidth: number;
  offsetHeight: number;
}

function makeStub(w = 400, h = 300): StubElement {
  const el: StubElement = {
    style: {},
    _listeners: [],
    addEventListener(type, handler, options): void {
      el._listeners.push({ type, handler, options });
    },
    removeEventListener(type, handler): void {
      const idx = el._listeners.findIndex(l => l.type === type && l.handler === handler);
      if (idx >= 0) el._listeners.splice(idx, 1);
    },
    getBoundingClientRect(): { left: number; top: number; width: number; height: number; right: number; bottom: number } {
      return { left: 0, top: 0, width: w, height: h, right: w, bottom: h };
    },
    clientWidth: w,
    clientHeight: h,
    offsetWidth: w,
    offsetHeight: h,
  };
  return el;
}

describe('attachPinchZoom — initial state', () => {
  let viewport: StubElement;
  let target: StubElement;

  beforeEach(() => {
    viewport = makeStub(400, 300);
    target = makeStub(400, 300);
  });

  it('applies initial transform with scale=1 and tx=0, ty=0', () => {
    attachPinchZoom(viewport as unknown as HTMLElement, target as unknown as HTMLElement);
    expect(target.style['transform']).toBe('translate(0px, 0px) scale(1)');
  });

  it('registers touch event listeners on viewport', () => {
    attachPinchZoom(viewport as unknown as HTMLElement, target as unknown as HTMLElement);
    const types = viewport._listeners.map(l => l.type);
    expect(types).toContain('touchstart');
    expect(types).toContain('touchmove');
    expect(types).toContain('touchend');
  });

  it('returns an object with destroy and reset methods', () => {
    const ctrl = attachPinchZoom(viewport as unknown as HTMLElement, target as unknown as HTMLElement);
    expect(typeof ctrl.destroy).toBe('function');
    expect(typeof ctrl.reset).toBe('function');
  });
});

describe('attachPinchZoom — reset', () => {
  it('reset returns transform to scale=1 and tx=0, ty=0', () => {
    const viewport = makeStub();
    const target = makeStub();
    const ctrl = attachPinchZoom(viewport as unknown as HTMLElement, target as unknown as HTMLElement);
    // Simulate external state mutation via internal reset path
    ctrl.reset();
    expect(target.style['transform']).toBe('translate(0px, 0px) scale(1)');
  });
});

describe('attachPinchZoom — destroy', () => {
  it('destroy removes all registered listeners', () => {
    const viewport = makeStub();
    const target = makeStub();
    const ctrl = attachPinchZoom(viewport as unknown as HTMLElement, target as unknown as HTMLElement);
    const listenersBefore = viewport._listeners.length;
    expect(listenersBefore).toBeGreaterThan(0);
    ctrl.destroy();
    expect(viewport._listeners.length).toBe(0);
  });

  it('destroy is idempotent — calling twice does not throw', () => {
    const viewport = makeStub();
    const target = makeStub();
    const ctrl = attachPinchZoom(viewport as unknown as HTMLElement, target as unknown as HTMLElement);
    ctrl.destroy();
    expect(() => ctrl.destroy()).not.toThrow();
  });
});

describe('attachPinchZoom — pinch math', () => {
  /**
   * Simulate a touch event by directly invoking the registered handler with a synthetic
   * object shaped like a TouchEvent. This tests the internal scale calculation without
   * relying on JSDOM TouchEvent support (which JSDOM lacks).
   */
  interface FakeTouch { clientX: number; clientY: number; identifier: number }
  function fakeTouchEvent(type: string, touches: FakeTouch[]): Event {
    return {
      type,
      touches,
      targetTouches: touches,
      changedTouches: touches,
      preventDefault(): void {},
      stopPropagation(): void {},
    } as unknown as Event;
  }

  function findHandler(el: StubElement, type: string): EventListenerOrEventListenerObject | undefined {
    const entry = el._listeners.find(l => l.type === type);
    return entry?.handler;
  }

  function invoke(h: EventListenerOrEventListenerObject | undefined, ev: Event): void {
    if (!h) return;
    if (typeof h === 'function') h(ev);
    else h.handleEvent(ev);
  }

  it('two-finger pinch doubles the scale when distance doubles', () => {
    const viewport = makeStub(400, 300);
    const target = makeStub(400, 300);
    attachPinchZoom(viewport as unknown as HTMLElement, target as unknown as HTMLElement);

    const ts = findHandler(viewport, 'touchstart');
    const tm = findHandler(viewport, 'touchmove');

    // Start pinch with touches 100px apart (horizontal)
    invoke(ts, fakeTouchEvent('touchstart', [
      { clientX: 150, clientY: 150, identifier: 0 },
      { clientX: 250, clientY: 150, identifier: 1 },
    ]));
    // Move to 200px apart (double distance)
    invoke(tm, fakeTouchEvent('touchmove', [
      { clientX: 100, clientY: 150, identifier: 0 },
      { clientX: 300, clientY: 150, identifier: 1 },
    ]));

    const tr = target.style['transform'] ?? '';
    // scale should be ~2
    const m = tr.match(/scale\(([\d.]+)\)/);
    expect(m).toBeTruthy();
    const scale = m ? parseFloat(m[1] ?? '0') : 0;
    expect(scale).toBeGreaterThan(1.9);
    expect(scale).toBeLessThan(2.1);
  });

  it('scale is clamped to maximum of 8', () => {
    const viewport = makeStub(400, 300);
    const target = makeStub(400, 300);
    attachPinchZoom(viewport as unknown as HTMLElement, target as unknown as HTMLElement);

    const ts = findHandler(viewport, 'touchstart');
    const tm = findHandler(viewport, 'touchmove');

    // Start 10px apart
    invoke(ts, fakeTouchEvent('touchstart', [
      { clientX: 195, clientY: 150, identifier: 0 },
      { clientX: 205, clientY: 150, identifier: 1 },
    ]));
    // Move to 300px apart — raw ratio is 30, but clamp to 8
    invoke(tm, fakeTouchEvent('touchmove', [
      { clientX: 50, clientY: 150, identifier: 0 },
      { clientX: 350, clientY: 150, identifier: 1 },
    ]));

    const tr = target.style['transform'] ?? '';
    const m = tr.match(/scale\(([\d.]+)\)/);
    const scale = m ? parseFloat(m[1] ?? '0') : 0;
    expect(scale).toBeLessThanOrEqual(8);
    expect(scale).toBeGreaterThan(7);
  });

  it('scale is clamped to minimum of 1', () => {
    const viewport = makeStub(400, 300);
    const target = makeStub(400, 300);
    attachPinchZoom(viewport as unknown as HTMLElement, target as unknown as HTMLElement);

    const ts = findHandler(viewport, 'touchstart');
    const tm = findHandler(viewport, 'touchmove');

    // Start 200px apart
    invoke(ts, fakeTouchEvent('touchstart', [
      { clientX: 100, clientY: 150, identifier: 0 },
      { clientX: 300, clientY: 150, identifier: 1 },
    ]));
    // Move to 20px apart — raw ratio is 0.1, clamp to 1
    invoke(tm, fakeTouchEvent('touchmove', [
      { clientX: 190, clientY: 150, identifier: 0 },
      { clientX: 210, clientY: 150, identifier: 1 },
    ]));

    const tr = target.style['transform'] ?? '';
    const m = tr.match(/scale\(([\d.]+)\)/);
    const scale = m ? parseFloat(m[1] ?? '0') : 0;
    expect(scale).toBeGreaterThanOrEqual(1);
  });
});

describe('attachPinchZoom — single-touch pan at scale=1', () => {
  interface FakeTouch { clientX: number; clientY: number; identifier: number }
  function fakeTouchEvent(type: string, touches: FakeTouch[]): Event {
    return {
      type,
      touches,
      targetTouches: touches,
      changedTouches: touches,
      preventDefault(): void {},
      stopPropagation(): void {},
    } as unknown as Event;
  }
  function findHandler(el: StubElement, type: string): EventListenerOrEventListenerObject | undefined {
    const entry = el._listeners.find(l => l.type === type);
    return entry?.handler;
  }
  function invoke(h: EventListenerOrEventListenerObject | undefined, ev: Event): void {
    if (!h) return;
    if (typeof h === 'function') h(ev);
    else h.handleEvent(ev);
  }

  it('single-finger move at scale=1 does NOT pan (tx,ty stay 0)', () => {
    const viewport = makeStub(400, 300);
    const target = makeStub(400, 300);
    attachPinchZoom(viewport as unknown as HTMLElement, target as unknown as HTMLElement);

    const ts = findHandler(viewport, 'touchstart');
    const tm = findHandler(viewport, 'touchmove');

    invoke(ts, fakeTouchEvent('touchstart', [{ clientX: 100, clientY: 100, identifier: 0 }]));
    invoke(tm, fakeTouchEvent('touchmove', [{ clientX: 200, clientY: 200, identifier: 0 }]));

    const tr = target.style['transform'] ?? '';
    expect(tr).toMatch(/translate\(0px,\s*0px\)/);
  });
});
