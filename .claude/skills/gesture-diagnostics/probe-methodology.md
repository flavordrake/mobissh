# Progressive Isolation via Minimal Prototype

When gestures produce zero DOM events or unexpected behavior, the fastest way to find the break point is to build a minimal test page and progressively add application components until something breaks. This is a binary search on complexity.

**When to use:** When instrumentation (see instrumentation-cookbook.md) reveals touches aren't reaching the DOM, or behavior differs between a tap and a swipe.

## The Diagnostic Page

`public/gesture-probe.html` — standalone page served by the same server, accessible at the same origin. Absolute minimum viable swipe catcher:

```html
<!DOCTYPE html>
<html>
<head>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    * { margin: 0; padding: 0; }
    #target {
      width: 100vw; height: 100vh;
      background: #222; color: #0f0;
      font: 14px monospace;
      overflow-y: auto;
    }
    .event { padding: 2px 8px; border-bottom: 1px solid #333; }
  </style>
</head>
<body>
  <div id="target"></div>
  <script>
    const t = document.getElementById('target');
    let id = 0;
    function log(type, e) {
      const touch = e.touches[0] || e.changedTouches[0];
      const div = document.createElement('div');
      div.className = 'event';
      div.textContent = `${++id} ${type} x=${touch?.clientX?.toFixed(0)} y=${touch?.clientY?.toFixed(0)} touches=${e.touches.length}`;
      t.appendChild(div);
      t.scrollTop = t.scrollHeight;
      window.__probeEvents = window.__probeEvents || [];
      window.__probeEvents.push({ id, type, clientX: touch?.clientX, clientY: touch?.clientY, touches: e.touches.length, ts: Date.now() });
    }
    t.addEventListener('touchstart', e => log('start', e));
    t.addEventListener('touchmove', e => log('move', e));
    t.addEventListener('touchend', e => log('end', e));
  </script>
</body>
</html>
```

## Progressive Complexity Layers

Add one thing at a time. The moment gestures stop producing DOM events, you've found the breaking layer.

| Layer | What to Add | Tests |
|-------|------------|-------|
| **L0: Bare div** | Just the probe page | Tap + swipe. Both should produce events |
| **L1: touch-action: none** | Add `touch-action: none` to CSS | If swipe now fails, Chrome compositor was consuming it |
| **L2: passive: false** | Add `{ passive: false }` to touchstart | If breaks, compositor intervention triggered |
| **L3: preventDefault** | Call `e.preventDefault()` in touchstart | If breaks, Chrome "slow scroll" intervention |
| **L4: xterm.js** | Load xterm.js, create Terminal, open in `#target` | If breaks, xterm.js handlers consuming events |
| **L5: Our handlers** | Import and initialize ime.ts scroll handler | If breaks, our handler code is the problem |
| **L6: Full app** | Navigate to the real app page | If L5 passed but L6 fails, CSS/overlay/modal blocking |

## Interpreting Results

| L0 | L1 | L2 | L3 | L4 | L5 | Diagnosis |
|----|----|----|----|----|-----|-----------|
| FAIL | - | - | - | - | - | System-level: navigation gesture, native dialog, wrong coordinates |
| PASS | FAIL | - | - | - | - | `touch-action: none` interaction with Chrome |
| PASS | PASS | FAIL | - | - | - | Compositor intervention from `passive: false` |
| PASS | PASS | PASS | FAIL | - | - | `preventDefault` blocks Chrome gesture pipeline |
| PASS | PASS | PASS | PASS | FAIL | - | xterm.js touch handlers interfere |
| PASS | PASS | PASS | PASS | PASS | FAIL | Our handler code is the problem |
| PASS | PASS | PASS | PASS | PASS | PASS | CSS/layout issue specific to full app |

## Automated Probe Test

```javascript
test('gesture probe: bare div receives swipe', async ({ page }) => {
  await page.goto(baseURL + 'gesture-probe.html');
  await page.waitForSelector('#target');
  await page.evaluate(() => { window.__probeEvents = []; });

  // Perform swipe (Appium or ADB)
  // ...

  const events = await page.evaluate(() => window.__probeEvents);
  const starts = events.filter(e => e.type === 'start');
  const moves = events.filter(e => e.type === 'move');
  const ends = events.filter(e => e.type === 'end');
  expect(starts.length).toBeGreaterThan(0);
  expect(moves.length).toBeGreaterThan(0);
  expect(ends.length).toBeGreaterThan(0);
});
```

## CDP Context Isolation Note

On Android Chrome via CDP, page-script globals (`window.__probeEvents` set in `<script>` tags) are NOT visible to `page.evaluate()`. All instrumentation MUST be injected and read via `page.evaluate()`, never relied upon from inline scripts.

With Appium in WEBVIEW context, `driver.executeScript()` should have access to the same execution context. Verify this during migration.
