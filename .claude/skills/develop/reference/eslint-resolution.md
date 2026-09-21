# ESLint Resolution Guide — MobiSSH

## Config Structure
`.eslintrc.json` has path-scoped overrides:
- `server/**/*.js`, `server-feedback/**/*.js` — node + commonjs
- `public/**/*.js` — browser globals, module scope
- `server/**/*.js` — node globals, commonjs
- `test/**/*.js` — node + commonjs (the infra tests)

## Most Common Lint Errors and Fixes

### `@typescript-eslint/no-explicit-any` (error)
```typescript
// BAD
function handle(data: any) { ... }

// GOOD — use the actual type
function handle(data: ServerMessage) { ... }

// GOOD — use unknown + type guard
function handle(data: unknown) {
  if (typeof data === 'object' && data !== null && 'type' in data) { ... }
}
```

### `@typescript-eslint/no-non-null-assertion` (warning)
```typescript
// Acceptable where element is guaranteed to exist
const el = document.getElementById('app')!;

// Preferred — null check
const el = document.getElementById('app');
if (!el) throw new Error('Missing #app');
```

### `no-unused-vars` (warning)
```typescript
// Use _ prefix for intentionally unused params
function handler(_event: Event, data: string) { ... }

// Use _ prefix for unused destructured values
const { used, _unused } = someObject;
```

### `@typescript-eslint/no-floating-promises` (error in strict)
```typescript
// BAD — promise ignored
someAsyncFn();

// GOOD — explicit void
void someAsyncFn();

// GOOD — await in async context
await someAsyncFn();
```

### `@typescript-eslint/no-misused-promises` (error in strict)
```typescript
// BAD — async function as event handler
el.addEventListener('click', async () => { ... });

// GOOD — wrap in void
el.addEventListener('click', () => { void handleClick(); });

// Or handle the promise explicitly
el.addEventListener('click', () => {
  handleClick().catch(err => console.error(err));
});
```

## Fixing Lint Errors in Your Changes Only
- Run `npx eslint --no-error-on-unmatched-pattern <your-files>` to check specific files
- Do NOT fix pre-existing warnings in files you didn't modify
- If a pre-existing error blocks your build, note it in the PR body

## Semgrep Integration
`npm run lint` covers the JS that is left; `npm run semgrep` runs the custom rules.
Semgrep errors to watch for:
- `plaintext-secret-storage` — never put passwords in localStorage
- `duplicate-event-listener` — consolidate or add cleanup
- `no-waitForSelector-hidden-class` — use locator API instead
