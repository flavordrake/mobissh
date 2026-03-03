# Gesture Instrumentation Cookbook

Code recipes for instrumenting touch/gesture events. Tool-agnostic — works with Playwright `page.evaluate()` or Appium `driver.executeScript()` in WEBVIEW context.

## Touch Event Tracing

Inject DOM-level touch listeners to observe what events actually fire, on which elements, with what coordinates.

```javascript
// Inject BEFORE the gesture under test
await page.evaluate(() => {
  window.__touchTrace = [];
  const log = (src, type, e) => {
    const t = e.touches[0] || e.changedTouches[0];
    window.__touchTrace.push({
      src, type,
      clientX: t ? t.clientX : null,
      clientY: t ? t.clientY : null,
      screenX: t ? t.screenX : null,
      screenY: t ? t.screenY : null,
      touches: e.touches.length,
      cancelable: e.cancelable,
      defaultPrevented: e.defaultPrevented,
      ts: Date.now()
    });
  };
  const term = document.getElementById('terminal');
  term.addEventListener('touchstart', e => log('term-cap', 'start', e), { capture: true });
  term.addEventListener('touchmove', e => log('term-cap', 'move', e), { capture: true });
  term.addEventListener('touchend', e => log('term-cap', 'end', e), { capture: true });
  document.addEventListener('touchstart', e => log('doc-bub', 'start', e));
  document.addEventListener('touchmove', e => log('doc-bub', 'move', e));
  document.addEventListener('touchend', e => log('doc-bub', 'end', e));
});
```

## Viewport State Polling

Poll xterm.js viewport state during the gesture to see if/when it changes:

```javascript
await page.evaluate(() => {
  window.__vpSnapshots = [];
  window.__vpInterval = setInterval(() => {
    const t = window.__testTerminal;
    if (t) {
      const b = t.buffer.active;
      window.__vpSnapshots.push({
        viewportY: b.viewportY, baseY: b.baseY, ts: Date.now()
      });
    }
  }, 100);
});
```

## Console Log Capture

Our handlers prefix logs with `[scroll]`, `[pinch]`, etc.:

```javascript
const consoleLogs = [];
page.on('console', msg => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
```

## Pre-Gesture State Snapshot

Capture starting conditions before triggering any gesture:

```javascript
const preState = await page.evaluate(() => ({
  naturalVerticalScroll: localStorage.getItem('naturalVerticalScroll'),
  naturalHorizontalScroll: localStorage.getItem('naturalHorizontalScroll'),
  enablePinchZoom: localStorage.getItem('enablePinchZoom'),
  mouseMode: window.__testTerminal?.modes?.mouseTrackingMode,
  viewportY: window.__testTerminal?.buffer.active.viewportY,
  baseY: window.__testTerminal?.buffer.active.baseY,
  fontSize: window.__testTerminal?.options.fontSize,
}));
```

## Diagnostic Report Assembly

Collect all instrumentation data and write to a file or attach as test artifact:

```javascript
const trace = await page.evaluate(() => {
  clearInterval(window.__vpInterval);
  return {
    touchEvents: window.__touchTrace,
    vpSnapshots: window.__vpSnapshots,
  };
});

const report = [
  `Settings: ${JSON.stringify(preState)}`,
  `Bounds: ${JSON.stringify(bounds)}`,
  '',
  `Touch events (${trace.touchEvents.length}):`,
  ...trace.touchEvents.map(e =>
    `  ${e.src} ${e.type} clientY=${e.clientY} screenY=${e.screenY} touches=${e.touches} cancelable=${e.cancelable} defaultPrevented=${e.defaultPrevented}`
  ),
  '',
  `VP snapshots (${trace.vpSnapshots.length}):`,
  ...trace.vpSnapshots.map(s => `  viewportY=${s.viewportY} baseY=${s.baseY}`),
  '',
  `Console logs:`,
  ...consoleLogs.filter(l => l.includes('[scroll]') || l.includes('[pinch]')),
].join('\n');

// Option A: Playwright test artifact
await testInfo.attach('gesture-diagnostic', {
  body: Buffer.from(report), contentType: 'text/plain',
});

// Option B: File (works with any runner)
require('fs').writeFileSync('/tmp/gesture-diagnostic.txt', report);
```

## Interpreting Diagnostic Output

| Symptom | Likely Cause |
|---------|-------------|
| Zero events at any level | Touch not reaching Chrome (native dialog, system gesture, wrong coordinates) |
| Zero touchmove events | Touch lands on element but ADB coordinates miss it; check bounds |
| touchstart but no touchmove | Touch lands on element but moves outside it; check element size |
| Events on doc-bub but not term-cap | z-index, pointer-events CSS, or overlapping element blocking |
| Events on term-cap but not doc-bub | stopPropagation in capture phase |
| viewportY unchanged despite touchmoves | Handler not calling scrollLines, or another handler overriding |
| `defaultPrevented: true` on touchstart | Something called preventDefault; browser will block scroll |
| `bounds.top` negative | Coordinate translation broken |

## addEventListener Registry (Advanced)

Monkey-patch `addEventListener` to trace ALL handler registrations, including library-registered handlers invisible to source searches. Must inject via `page.addInitScript()` before page load.

```javascript
await page.addInitScript(() => {
  window.__handlerRegistry = [];
  const origAdd = EventTarget.prototype.addEventListener;
  EventTarget.prototype.addEventListener = function(type, fn, opts) {
    if (/^touch|^pointer|^click|^mouse/.test(type)) {
      window.__handlerRegistry.push({
        target: this === document ? 'document' : this === window ? 'window'
          : (this.id || this.tagName || this.className || 'unknown'),
        type,
        capture: !!(opts && (opts === true || opts.capture)),
        passive: opts && typeof opts === 'object' ? (opts.passive ?? true) : true,
        stack: new Error().stack?.split('\n').slice(1, 4).join(' < '),
        ts: Date.now()
      });
    }
    return origAdd.call(this, type, fn, opts);
  };
});
```

After page load, dump the registry:

```javascript
const registry = await page.evaluate(() => window.__handlerRegistry);
// Shows: target | type | capture | passive | registered-by (stack trace)
```

This catches xterm.js handlers, framework handlers, and any library-registered listeners.

## Element Chain Instrumentation

When circling on touch delivery issues, instrument every element from `#terminal` down to canvas. This is the "L6 test" approach from gesture-probe.spec.js.

```javascript
await page.evaluate(() => {
  const chain = [];
  let el = document.getElementById('terminal');
  while (el) {
    const info = {
      tag: el.tagName,
      id: el.id,
      className: el.className,
      touchAction: getComputedStyle(el).touchAction,
      pointerEvents: getComputedStyle(el).pointerEvents,
      events: { start: 0, move: 0, end: 0 }
    };
    el.addEventListener('touchstart', () => info.events.start++);
    el.addEventListener('touchmove', () => info.events.move++);
    el.addEventListener('touchend', () => info.events.end++);
    chain.push(info);
    el = el.firstElementChild;
  }
  window.__elementChain = chain;
});

// After gesture:
const chain = await page.evaluate(() => window.__elementChain);
// Shows which DOM level received events and which didn't
```
