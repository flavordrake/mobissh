---
paths:
  - "src/**/*.ts"
  - "tsconfig.json"
---

# TypeScript

- Source lives in `src/modules/*.ts`, compiled to `public/modules/*.js` via `tsc`.
- Strict mode: `strict: true`, `noUncheckedIndexedAccess: true`, `verbatimModuleSyntax: true`.
- Import extensions: source uses `.js` extensions; `moduleResolution: "bundler"` resolves to `.ts`.
- Shared interfaces in `src/modules/types.ts`. Ambient types for globals in `src/types/xterm-globals.d.ts`.
- Server (`server/index.js`) stays plain JS, not in scope for TS migration.
- Always run `npx tsc` after cherry-picking commits that touch TS source. Compiled JS may be stale.

## IME module conventions
- **State machine is the source of truth** for all composition behavior. 4 states: `idle`, `composing`, `previewing`, `editing`. All transitions through `_transition()`. Never add parallel boolean flags or external detection logic.
- **Voice vs swipe distinction belongs in the state machine**, not in separate event listeners. Track composition source as part of the transition, not via external viewport/touch detection.
- **Terminal writes are batched per `requestAnimationFrame`** (`_bufferTerminalWrite` in connection.ts). Never call `terminal.write()` directly from WS message handlers — use the buffer.
- **Transfer list rendering is rAF-throttled.** Call `_renderTransferList()` freely — it coalesces into one DOM update per frame.
