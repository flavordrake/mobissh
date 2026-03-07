# TypeScript Best Practices — MobiSSH

## Compiler Config
- `strict: true`, `noUncheckedIndexedAccess: true`, `verbatimModuleSyntax: true`
- Target: ES2022, Module: ES2022, moduleResolution: bundler
- Source: `src/` → Output: `public/` (via `npx tsc`)

## Import Conventions
```typescript
// Always use .js extensions in imports (bundler resolution finds .ts)
import { appState } from './state.js';
import { THEMES } from './constants.js';

// Type-only imports for zero runtime cost
import type { SSHProfile, AppState } from './types.js';
```

## Type Patterns

### Use discriminated unions for messages/events
```typescript
export type ServerMessage =
  | { type: 'connected' }
  | { type: 'output'; data: string }
  | { type: 'error'; message: string };
```

### Use interface for data shapes, type for unions
```typescript
export interface SSHProfile {
  name: string;
  host: string;
  port: number;
  authType: 'password' | 'key';
}
export type ConnectionStatus = 'connecting' | 'connected' | 'disconnected';
```

### Deps interfaces for DI
```typescript
export interface ConnectionDeps {
  toast: (msg: string) => void;
  setStatus: (state: ConnectionStatus, text: string) => void;
}
```

## Null Handling
- `noUncheckedIndexedAccess` means array access returns `T | undefined`
- Use `!` assertion sparingly (eslint warns), prefer null checks
- DOM elements: cast with `as HTMLInputElement | null`, then null-check
```typescript
const el = document.getElementById('foo') as HTMLInputElement | null;
if (!el) return;
el.value = 'bar';
```

## Common Mistakes to Avoid
- **Don't use `any`** — `@typescript-eslint/no-explicit-any` is an error
- **Don't forget .js extensions** — bare `'./state'` won't resolve
- **Don't import from `public/`** — always import from `src/` (TS source)
- **Don't add `export default`** — project uses named exports only
- **Don't create barrel files** (`index.ts`) — each module imports directly
- **Don't add runtime type checks** for internal data — trust the type system
- **Don't forget `verbatimModuleSyntax`** — use `import type` for type-only imports

## Adding New Modules
1. Create `src/modules/yourmodule.ts`
2. Export an `initYourModule(deps: YourDeps)` function
3. Add `YourDeps` interface to `types.ts`
4. Wire DI in `app.ts`
5. Compiled output `public/modules/yourmodule.js` is gitignored

## Type Checking
```bash
npx tsc --noEmit     # Check only, no output
npx tsc              # Full compile to public/
```
Always run `--noEmit` first — faster feedback loop.
