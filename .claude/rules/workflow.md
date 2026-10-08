# MobiSSH Workflow

## Issue workflow
- Process documentation in `.claude/process.md` defines label taxonomy, workflow states, delegation lifecycle.
- `bot` <> `divergence` lifecycle: delegate applies bot, integrate swaps to divergence on failure, delegate swaps back on re-delegation.
- `blocked` label always requires an explanatory comment. `conflict` is transient (resolve within one cycle).

## PR checklist
Before submitting a PR, run the gate:
```
scripts/native-fast-gate.sh
```
Anything touching the session state machine, connect/auth, reconnect, SFTP or IPC
also needs the on-emulator tier — see `.claude/rules/testing.md`.

## Device testing
- Mobile UX features MUST be tested on real hardware before merging to main.
- Touch, gesture, keyboard, layout and viewport work is human-only for delegation: an
  agent cannot validate it, so `/delegate` does not hand it out as bot work.

## Develop briefs
The **Do NOT** list of every brief includes: no inline styles in `public/` HTML, no
extended timeouts or `pumpAndSettle` sleeps to paper over a race, no emojis in code or
UI text unless requested, no stale test fakes that don't match the real API.

For IME/input issues the north star is faithful input representation: the test asserts
the bytes the shell received equal what the user entered, in an on-emulator test in
`native/integration_test/`, not just the mechanics.

A test-fixup brief (UX approved, assertions outdated) scopes `native/test/` and
`native/integration_test/` only: no change under `native/lib/` or `server/`, no deleted
or skipped tests, no new test files.

## Integrate
- Gate each candidate with `scripts/integrate-gate.sh <branch-name>` (branch name, not
  issue number), alongside or instead of the gater's `fast` tier. It runs three tiers:
  the native fast gate, eslint over the remaining JS (`server/`, `server-feedback/`,
  `public/`, `test/`), and a coverage check that rejects a branch changing source
  (`native/lib`, server JS) with no test file changed. It prints `+ GATE PASSED` /
  `! GATE FAILED` and a `native | eslint | coverage` line; `--close-on-fail --pr N`
  closes the PR on failure.
- Integration-sensitive PRs (`scripts/integration-required.sh` decides) are refused by
  `scripts/gh-ops.sh integrate` until the `device` gate in `AGENTS.md` ran green against
  the baseline; then re-run with `--integration-verified`. Never pass the flag otherwise.
- `device`-labelled issues never merge on unit-gate results alone.
- Final acceptance after all merges: the `device` gate once. Read the suite verdict (an
  expected-pass failing fails the run; a known-red passing also fails it: promote it and
  bump the tally), check `test-results/uploads/` for bundles the run produced, and report
  "Integration: X expected-pass, Y known-red, Z unexpected". No lease: list the PRs that
  still need device validation.
- After the merges: `scripts/container-ctl.sh restart`. The owner tests on the prod
  container; a stale one shows old behaviour and produces false bug reports.
