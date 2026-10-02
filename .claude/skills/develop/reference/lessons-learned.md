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

### Widget test assertion fails, then a debug print shows it settled
Futures backed by the task gateway or SharedPreferences escape `testWidgets`' fake
clock; `pump()` never drains them. Tick `tester.runAsync` first. Fixed delays are
load-sensitive flakes: poll with a bounded timeout instead of sleeping longer.

### Headless green, broken on device
The fast gate excludes `native/integration_test/`. Changes to the session state
machine, connect/auth, reconnect, SFTP or the isolate IPC need the on-emulator tier
(`.claude/rules/testing.md`).

## Security
- NEVER store passwords/keys in SharedPreferences or plain files — use `secrets_store.dart`
- NEVER log sensitive data (telemetry rings and bug reports leave the device)
- AES-GCM requires unique nonces — never reuse one across encryptions
