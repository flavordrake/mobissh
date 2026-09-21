---
paths:
  - "native/**/*"
  - "test/**/*"
  - "scripts/*gate*.sh"
---

# Testing

## Test gates (run before PR)
```
scripts/native-fast-gate.sh   # gate 0 rule tests + infra tests + analyze + flutter unit
```
Add `--with-integration` for the on-emulator tier (see the contract below), and
lease a device with `scripts/with-fleet-emulator.sh` to run it.

## Infrastructure tests (`test/infra/`, node:test)
The non-Flutter infrastructure — `server/feedback-guard.js`, `server/manifest.js`,
`scripts/notify-parse.sh`, the TRACE scripts, `scripts/termux-bootstrap.sh` —
is covered by `test/infra/*.test.js`, run by `scripts/test-infra.sh` from fast
gate 0.

- **node:test, never a test framework with npm dependencies.** Agent worktrees have
  no `node_modules` (gitignored, never copied), so a gate step needing npm deps is
  unrunnable exactly where agents gate. `node --test` needs nothing but node.
- A test that shells out to a credentialed tool (e.g. `gh`) skips LOUDLY when the
  credential is absent; it never soft-passes.

## Native Flutter gate (#501 rewrite, `native/`) — #589 contract
The native app is the product; this is its gate.

- **Fast gate (every commit):** `scripts/native-fast-gate.sh` = gate 0 (bash rule
  tests + `scripts/test-infra.sh`) + `flutter analyze` +
  `flutter test --exclude-tags integration`. It CANNOT boot an emulator, so it runs
  only headless unit + widget tests. This is necessary but NOT sufficient.
  It is also what CI runs (`.github/workflows/ci.yml`).
- **Integration suite (merge/release gate):** `scripts/native-integration-suite.sh`
  (or `native-fast-gate.sh --with-integration`) runs the FULL `native/integration_test/`
  suite on a booted emulator through the socat+adb-reverse bridge. These are the
  byte-flow / state-machine / lifecycle tests the fast gate EXCLUDES.
- **The rule:** any change touching the session **state machine, connect/auth,
  reconnect, multi-session, SFTP, or the UI↔task-isolate IPC** MUST pass the
  integration suite before merge. The fast gate passing is NOT enough — that is
  exactly how #539/#546/#547 and the #590 stale-shell hang shipped "green" and
  broke on device. An excluded test suite reads as coverage while gating nothing.
- **Terminal-flow gate (middle tier, owner directive 2026-07-01):**
  `scripts/terminal-flow-gate.sh` runs the two saga-critical end-to-end flows
  (`golden_flow_tui_test` — connect → tmux → TUI screen → detection RENDERS →
  scroll → verbatim gutter copy; and `gutter_copy_scrollback_test`) in ~10-15
  min. It is REQUIRED before shipping ANY change touching the terminal view,
  gesture routing, selection/gutter, the copy path, detection/anchors/marks, or
  the flterm fork (`native/third_party/flterm/`). The full suite is too slow
  per-ship and the fast gate excludes integration — that gap is how the +94
  long-press pivot silently broke the flagship copy test (found broken
  2026-07-01, `copied=null`, never re-run after the pivot). Gesture-model
  changes MUST update these tests in the same commit.
- **Prefer headless transition tests where possible.** If a state-transition can be
  reproduced via `InMemoryGatewayPair` (no real device), put it in `native/test/`
  so it runs in the fast gate on EVERY commit — e.g. `reconnect_shell_revive_test.dart`
  (#590), `sftp_download_reassembly_test.dart` (#591). Only behaviors that genuinely
  need a device (real socket, foreground service, host-key prompt) belong in
  `integration_test/`.
- **An integration test DECLARES what it needs, in its own header (#1101).** The
  runner derives its wiring from the test source — there is no list to add yourself
  to, and a runner-side list is the drift that made two tests fail as fake product
  regressions. `scripts/lib/integration-fixtures.sh` reads:
  - `2223` anywhere in the source → the second socat+adb-reverse bridge is armed
  - `jump-target` anywhere in the source → the second sshd container is brought up
  - `// Setup (run FIRST): scripts/x.sh` → run before the test; a failure FAILS the test
  - `// Teardown …: scripts/y.sh` → run after it, ALWAYS, including after a failure
  - `// Runner: scripts/z.sh …` → not an Android device test; z.sh owns it
  `scripts/test-integration-wiring.sh` (fast gate 0) pins this against every test on
  disk. Fixture setup scripts must honour `SSHD_HOST` — the runner pins it to an
  unambiguous container, so a hard-coded `test-sshd` seeds the wrong sshd.
- **The suite enforces an ACCEPTED BASELINE, not an all-green run (#1101/#1205).**
  `native/integration_test/BASELINE.manifest` is the record: 74 expected-pass of the
  84 discovered device tests, plus 10 known-red each with a one-line cause and the
  issue that owns it. The suite's verdict:
  - an **expected-pass** test fails → the suite FAILS (the reason the gate exists)
  - a **known-red** test fails → reported, not fatal
  - a **known-red** test PASSES → the suite FAILS: promote it to `expect` and bump the
    `accepted` tally, citing the run. A silently-recovered test that stays excused is
    how the list rots back into "22 reds, nobody knows why"
  - a test on disk in **neither** list → the suite FAILS, and fast gate 0 fails first
  **Adding an integration test means adding a manifest line** (and bumping the tally).
  `scripts/test-integration-wiring.sh` checks the manifest against every test on disk —
  no emulator, sub-second — so it cannot drift from the corpus. Never move a red into
  `known-red` to go green: a red that no issue owns is not a baseline, it is a hole.
- **Never silently skip the device tier.** `native-integration-suite.sh` exits
  non-zero with "NOT VALIDATED" when no emulator is present (unless
  `--allow-no-emulator` is passed explicitly). A missing emulator must never
  masquerade as a pass.
- **Test maintenance:** a native change to a gated subsystem that adds NO new
  transition test (headless or integration) is incomplete work.

## Test patterns
- **Prefer a headless transition test.** See the native contract above for which
  behaviours genuinely need a device.
- **Screenshots ARE the test.** Read them; assert visibility alongside data.
