---
paths:
  - "src/modules/ime.ts"
  - "src/modules/ime-diff.ts"
---

# IME Input Layer

## State machine is the source of truth

4 states: `idle`, `composing`, `previewing`, `editing`. All transitions go through `_transition()`.

- **Never add parallel boolean flags** or external detection logic to track composition state. If you need to know "are we composing?", check `_imeState`, don't add a new flag.
- **Voice vs swipe distinction belongs in the state machine.** Track composition source as part of the transition (e.g., `_compositionSource: 'keyboard' | 'voice'`), not via external viewport/touch event listeners racing with the state machine.
- **All UI visibility decisions** (textarea show/hide, action bar, preview styling) happen inside `_transition()`, not scattered across event handlers.

## Performance patterns

- **Terminal writes are batched per `requestAnimationFrame`** (`_bufferTerminalWrite` in connection.ts). Never call `terminal.write()` directly from WS message handlers.
- **Transfer list rendering is rAF-throttled.** `_renderTransferList()` coalesces into one DOM update per frame.
- **Canvas measurement context is cached** at module scope (`_measureCtx`). Don't create a new canvas per resize call.

## Diff algorithm

`ime-diff.ts` exports `computeDiff(oldVal, newVal)` — prefix-only algorithm. Backspace deletes from cursor (end of string), so only a common prefix can be preserved. Everything after the divergence point must be deleted and retyped. Do not add suffix optimization — it produces garbled output (#177).
