# Lessons Learned — MobiSSH Development History

These come from real project failures. They are not suggestions — they are rules.

## Over-Engineering
The single most common failure mode. The develop agent's job is to implement the minimum
change that satisfies acceptance criteria, not to "improve" the codebase.

**Symptoms:**
- PR touches >5 files for a "simple" change
- New helper/utility functions for one-time operations
- Abstraction layers that didn't exist before
- Config objects or feature flags for unconditional behavior
- Comments explaining obvious code

**Prevention:**
- Read the issue acceptance criteria literally
- Count your files before committing — if >3, reconsider
- If you wrote a helper, check if it's used more than once
- If you added a type that's only used in one place, inline it

## Wrong Approach
Bot builds the wrong thing because it misunderstood the issue or invented its own design.

**Prevention:**
- Read context snippets from the delegation carefully
- Match existing patterns — read adjacent code FIRST
- When the issue says "like X", read X and follow its pattern exactly
- Don't guess UX — if the issue doesn't specify how, flag it

## Scope Creep
Bot fixes the issue but also "improves" unrelated code, breaking things.

**Symptoms:**
- Lint warnings fixed in files you didn't need to touch
- Type annotations added to unchanged functions
- Renamed variables for "clarity"
- Refactored adjacent code "while I was here"

**Prevention:**
- Git diff before committing — review every line
- Remove any changes to files not in scope
- If you notice a real bug in adjacent code, note it in PR body, don't fix it

## Stale Base
Branch diverges from main, merge conflicts at integration time.

**Prevention:**
- Merge from main before every test cycle
- Keep PRs small and short-lived
- If your branch lives longer than 1 hour, merge main again

## Test Failures

### Type errors from cherry-pick
Compiled JS in `public/modules/` is gitignored. After checkout, run `npx tsc` to
regenerate. Stale compiled JS causes runtime errors that don't match source.

### Playwright: element not visible
Usually means the UI state is wrong, not that the test is broken. Check:
- Is a modal blocking the element?
- Is the keyboard covering it?
- Is the element in a hidden panel?

### Playwright: timeout waiting for selector
- Check selector is correct (DOM may have changed)
- Use `page.locator()` not `page.waitForSelector()`
- Check if element is in a different iframe or shadow DOM

### Vitest: module not found
- Check import extensions (must be `.js` not `.ts`)
- Check that `vi.stubGlobal()` runs before dynamic import
- Check `vitest.config.mts` for path aliases

## CSS Regressions
- Never use `!important` — fix specificity instead
- Check all three test projects (pixel-7, iphone-14, chromium)
- Mobile layout bugs often come from `vh` vs `dvh` or missing safe-area-insets

## Security
- NEVER store passwords/keys in localStorage — use the vault
- NEVER log sensitive data to console
- NEVER send credentials over ws:// (only wss://)
- The vault uses 600k PBKDF2 iterations — don't reduce this
- AES-GCM requires unique IVs — always generate fresh `crypto.getRandomValues(new Uint8Array(12))`
