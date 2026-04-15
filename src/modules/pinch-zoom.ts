/**
 * Pinch-zoom and pan controller for image/SVG previews (#456).
 *
 * Pure module: no imports from other project modules. Attaches Touch Event
 * listeners to a viewport element and transforms a target element within it.
 *
 * Behavior:
 *  - Two-finger pinch: zoom around midpoint of the two touches.
 *  - Single-finger drag: pan, only when scale > 1.
 *  - Double-tap: toggle 1x <-> 2x around tap point.
 *  - Momentum: after a pan, decay velocity with 0.92 per frame.
 *  - Scale clamped [1, 8]; translation clamped so image stays >=50% within viewport.
 */

export interface PinchZoomController {
  destroy(): void;
  reset(): void;
}

interface Disposable {
  type: string;
  handler: EventListener;
  options?: AddEventListenerOptions | boolean;
}

const MIN_SCALE = 1;
const MAX_SCALE = 8;
const DOUBLE_TAP_MS = 300;
const DOUBLE_TAP_DIST = 30;
const MOMENTUM_DECAY = 0.92;
const MOMENTUM_MIN_VELOCITY = 0.5;
const VELOCITY_WINDOW_MS = 100;

function clamp(v: number, lo: number, hi: number): number {
  return v < lo ? lo : v > hi ? hi : v;
}

function dist(ax: number, ay: number, bx: number, by: number): number {
  const dx = bx - ax;
  const dy = by - ay;
  return Math.sqrt(dx * dx + dy * dy);
}

export function attachPinchZoom(viewport: HTMLElement, target: HTMLElement): PinchZoomController {
  // Transform state
  let scale = 1;
  let tx = 0;
  let ty = 0;

  // Pinch state
  let pinchActive = false;
  let initialPinchDist = 0;
  let initialScale = 1;
  let pinchMidX = 0;
  let pinchMidY = 0;
  let initialTx = 0;
  let initialTy = 0;

  // Pan state
  let panActive = false;
  let panStartX = 0;
  let panStartY = 0;
  let panStartTx = 0;
  let panStartTy = 0;
  const velSamples: { t: number; x: number; y: number }[] = [];

  // Double-tap state
  let lastTapTime = 0;
  let lastTapX = 0;
  let lastTapY = 0;

  // Momentum animation handle
  let momentumRaf = 0;

  // Disposable listeners
  const disposables: Disposable[] = [];

  function addListener(type: string, handler: EventListener, options?: AddEventListenerOptions | boolean): void {
    viewport.addEventListener(type, handler, options);
    disposables.push({ type, handler, options });
  }

  function applyTransform(): void {
    target.style.transform = `translate(${String(tx)}px, ${String(ty)}px) scale(${String(scale)})`;
  }

  function getBounds(): { maxTx: number; maxTy: number } {
    // Allow the scaled image to pan until at most half of it is off-screen.
    const vw = viewport.clientWidth || viewport.getBoundingClientRect().width || 0;
    const vh = viewport.clientHeight || viewport.getBoundingClientRect().height || 0;
    const tw = (target.offsetWidth || target.getBoundingClientRect().width || vw) * scale;
    const th = (target.offsetHeight || target.getBoundingClientRect().height || vh) * scale;
    const maxTx = Math.max(0, (tw - vw) / 2 + vw / 2);
    const maxTy = Math.max(0, (th - vh) / 2 + vh / 2);
    return { maxTx, maxTy };
  }

  function clampTranslate(): void {
    const { maxTx, maxTy } = getBounds();
    tx = clamp(tx, -maxTx, maxTx);
    ty = clamp(ty, -maxTy, maxTy);
  }

  function cancelMomentum(): void {
    if (momentumRaf) {
      const raf = typeof cancelAnimationFrame === 'function' ? cancelAnimationFrame : null;
      if (raf) raf(momentumRaf);
      momentumRaf = 0;
    }
  }

  function startMomentum(vx: number, vy: number): void {
    cancelMomentum();
    const raf = typeof requestAnimationFrame === 'function' ? requestAnimationFrame : null;
    if (!raf) return;
    let velX = vx;
    let velY = vy;
    const step = (): void => {
      velX *= MOMENTUM_DECAY;
      velY *= MOMENTUM_DECAY;
      tx += velX;
      ty += velY;
      const beforeTx = tx;
      const beforeTy = ty;
      clampTranslate();
      const hitBoundsX = beforeTx !== tx;
      const hitBoundsY = beforeTy !== ty;
      if (hitBoundsX) velX = 0;
      if (hitBoundsY) velY = 0;
      applyTransform();
      const speed = Math.sqrt(velX * velX + velY * velY);
      if (speed >= MOMENTUM_MIN_VELOCITY) {
        momentumRaf = raf(step);
      } else {
        momentumRaf = 0;
      }
    };
    momentumRaf = raf(step);
  }

  function recordVelocitySample(x: number, y: number): void {
    const now = typeof performance !== 'undefined' ? performance.now() : Date.now();
    velSamples.push({ t: now, x, y });
    // Keep only recent samples
    const cutoff = now - VELOCITY_WINDOW_MS;
    while (velSamples.length > 0 && velSamples[0]!.t < cutoff) {
      velSamples.shift();
    }
  }

  function computeVelocity(): { vx: number; vy: number } {
    if (velSamples.length < 2) return { vx: 0, vy: 0 };
    const first = velSamples[0]!;
    const last = velSamples[velSamples.length - 1]!;
    const dt = last.t - first.t;
    if (dt <= 0) return { vx: 0, vy: 0 };
    // px per frame, assuming ~16ms/frame
    const frameMs = 16;
    return {
      vx: ((last.x - first.x) / dt) * frameMs,
      vy: ((last.y - first.y) / dt) * frameMs,
    };
  }

  function onTouchStart(ev: Event): void {
    const e = ev as TouchEvent;
    cancelMomentum();
    if (e.touches.length === 2) {
      const t0 = e.touches[0]!;
      const t1 = e.touches[1]!;
      pinchActive = true;
      panActive = false;
      initialPinchDist = dist(t0.clientX, t0.clientY, t1.clientX, t1.clientY);
      initialScale = scale;
      pinchMidX = (t0.clientX + t1.clientX) / 2;
      pinchMidY = (t0.clientY + t1.clientY) / 2;
      initialTx = tx;
      initialTy = ty;
      if (typeof e.preventDefault === 'function') e.preventDefault();
    } else if (e.touches.length === 1) {
      const t0 = e.touches[0]!;
      // Double-tap detection
      const now = typeof performance !== 'undefined' ? performance.now() : Date.now();
      const dtTap = now - lastTapTime;
      const distTap = dist(lastTapX, lastTapY, t0.clientX, t0.clientY);
      if (dtTap < DOUBLE_TAP_MS && distTap < DOUBLE_TAP_DIST) {
        // Double-tap fires: handle on touchend for accuracy — but mark for processing
        lastTapTime = 0;
        handleDoubleTap(t0.clientX, t0.clientY);
        return;
      }
      lastTapTime = now;
      lastTapX = t0.clientX;
      lastTapY = t0.clientY;

      // Start pan only if zoomed in
      if (scale > 1) {
        panActive = true;
        panStartX = t0.clientX;
        panStartY = t0.clientY;
        panStartTx = tx;
        panStartTy = ty;
        velSamples.length = 0;
        recordVelocitySample(t0.clientX, t0.clientY);
        if (typeof e.preventDefault === 'function') e.preventDefault();
      }
    }
  }

  function handleDoubleTap(cx: number, cy: number): void {
    if (scale > 1.01) {
      // Reset
      scale = 1;
      tx = 0;
      ty = 0;
    } else {
      // Zoom to 2x around tap point
      const rect = viewport.getBoundingClientRect();
      const vx = cx - rect.left;
      const vy = cy - rect.top;
      const newScale = 2;
      // Keep tap point anchored: new_t = v - (v - old_t) * (newScale/oldScale)
      tx = vx - (vx - tx) * (newScale / scale);
      ty = vy - (vy - ty) * (newScale / scale);
      scale = newScale;
      clampTranslate();
    }
    applyTransform();
  }

  function onTouchMove(ev: Event): void {
    const e = ev as TouchEvent;
    if (pinchActive && e.touches.length === 2) {
      const t0 = e.touches[0]!;
      const t1 = e.touches[1]!;
      const currentDist = dist(t0.clientX, t0.clientY, t1.clientX, t1.clientY);
      const ratio = initialPinchDist > 0 ? currentDist / initialPinchDist : 1;
      const newScale = clamp(initialScale * ratio, MIN_SCALE, MAX_SCALE);
      // Zoom around initial midpoint: keep that point anchored in target coords
      const rect = viewport.getBoundingClientRect();
      const vmx = pinchMidX - rect.left;
      const vmy = pinchMidY - rect.top;
      const ratioApplied = newScale / initialScale;
      tx = vmx - (vmx - initialTx) * ratioApplied;
      ty = vmy - (vmy - initialTy) * ratioApplied;
      scale = newScale;
      clampTranslate();
      applyTransform();
      if (typeof e.preventDefault === 'function') e.preventDefault();
      return;
    }

    if (panActive && e.touches.length === 1 && scale > 1) {
      const t0 = e.touches[0]!;
      const dx = t0.clientX - panStartX;
      const dy = t0.clientY - panStartY;
      tx = panStartTx + dx;
      ty = panStartTy + dy;
      clampTranslate();
      applyTransform();
      recordVelocitySample(t0.clientX, t0.clientY);
      if (typeof e.preventDefault === 'function') e.preventDefault();
    }
  }

  function onTouchEnd(ev: Event): void {
    const e = ev as TouchEvent;
    if (pinchActive) {
      // Pinch ends when fewer than 2 touches remain
      if (e.touches.length < 2) {
        pinchActive = false;
        // If one finger remains and we're zoomed in, transition to pan
        if (e.touches.length === 1 && scale > 1) {
          const t0 = e.touches[0]!;
          panActive = true;
          panStartX = t0.clientX;
          panStartY = t0.clientY;
          panStartTx = tx;
          panStartTy = ty;
          velSamples.length = 0;
        }
      }
      return;
    }

    if (panActive && e.touches.length === 0) {
      panActive = false;
      const { vx, vy } = computeVelocity();
      if (Math.abs(vx) >= MOMENTUM_MIN_VELOCITY || Math.abs(vy) >= MOMENTUM_MIN_VELOCITY) {
        startMomentum(vx, vy);
      }
    }
  }

  // Register listeners
  addListener('touchstart', onTouchStart as EventListener, { passive: false });
  addListener('touchmove', onTouchMove as EventListener, { passive: false });
  addListener('touchend', onTouchEnd as EventListener);
  addListener('touchcancel', onTouchEnd as EventListener);

  // Initial transform
  applyTransform();

  return {
    destroy(): void {
      cancelMomentum();
      while (disposables.length > 0) {
        const d = disposables.pop();
        if (!d) break;
        viewport.removeEventListener(d.type, d.handler, d.options);
      }
    },
    reset(): void {
      cancelMomentum();
      scale = 1;
      tx = 0;
      ty = 0;
      applyTransform();
    },
  };
}
