# Gesture Instrumentation Cookbook

Code recipes for instrumenting touch/gesture events. Works with Appium `driver.executeScript()` in WEBVIEW context or Playwright `page.evaluate()`.

## Touch Event Tracing

Inject before the gesture under test to observe what events fire, on which elements, with what coordinates.

```javascript
await driver.executeScript(`
  window.__touchTrace = [];
  const log = (src, type, e) => {
    const t = e.touches[0] || e.changedTouches[0];
    window.__touchTrace.push({
      src, type,
      clientX: t ? t.clientX : null,
      clientY: t ? t.clientY : null,
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
`, []);
```

## Viewport State Polling

Poll xterm.js viewport state during the gesture to see if/when it changes:

```javascript
await driver.executeScript(`
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
`, []);
```

## Pre-Gesture State Snapshot

Capture starting conditions before triggering any gesture:

```javascript
const preState = await driver.executeScript(`return {
  naturalVerticalScroll: localStorage.getItem('naturalVerticalScroll'),
  naturalHorizontalScroll: localStorage.getItem('naturalHorizontalScroll'),
  enablePinchZoom: localStorage.getItem('enablePinchZoom'),
  mouseMode: window.__testTerminal?.modes?.mouseTrackingMode,
  viewportY: window.__testTerminal?.buffer.active.viewportY,
  baseY: window.__testTerminal?.buffer.active.baseY,
  fontSize: window.__testTerminal?.options.fontSize,
}`, []);
```

## Collecting Results

```javascript
const trace = await driver.executeScript(`
  clearInterval(window.__vpInterval);
  return {
    touchEvents: window.__touchTrace || [],
    vpSnapshots: window.__vpSnapshots || [],
  };
`, []);
```

## Interpreting Diagnostic Output

| Symptom | Likely Cause |
|---|---|
| Zero events at any level | Touch not reaching Chrome (native dialog, system gesture, wrong coordinates) |
| touchstart but no touchmove | Touch lands on element but moves outside it; check element size |
| Events on doc-bub but not term-cap | z-index, pointer-events CSS, or overlapping element |
| Events on term-cap but not doc-bub | stopPropagation in capture phase |
| viewportY unchanged despite touchmoves | Handler not calling scrollLines, or another handler overriding |
| `defaultPrevented: true` on touchstart | Something called preventDefault; browser will block scroll |

## Handler Registry Dump

Monkey-patch `addEventListener` to trace ALL handler registrations including library code. Must inject before page load.

```javascript
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
    });
  }
  return origAdd.call(this, type, fn, opts);
};
```

## Element Chain Instrumentation

When circling on touch delivery issues, instrument every element from `#terminal` down to canvas:

```javascript
await driver.executeScript(`
  const chain = [];
  let el = document.getElementById('terminal');
  while (el) {
    const info = {
      tag: el.tagName, id: el.id, className: el.className,
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
`, []);

// After gesture:
const chain = await driver.executeScript('return window.__elementChain', []);
// Shows which DOM level received events and which didn't
```
