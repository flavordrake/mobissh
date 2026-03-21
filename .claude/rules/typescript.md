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
