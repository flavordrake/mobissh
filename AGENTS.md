# MobiSSH

Mobile-first SSH client: a Flutter app (`native/`) that speaks SSH directly via
dartssh2, used over Tailscale. The workflow skills and agents (`/cycle`, `/delegate`,
`/develop`, `/integrate`, `/issue`, `/release`, `/decompose`, `/write-tests`,
`/doc-parity`, agent-trace) come from the devloop plugin (`devloop@flavordrake`); this
file is the per-repo contract devloop reads. Agents read `.claude/constitution.md`
first; project rules are in `.claude/rules/` and override devloop defaults where they
differ.

## Project
- Default branch: main
- Version file: native/pubspec.yaml (`x.y.z[-STAGE]+B`, see docs/VERSIONING.md; `scripts/ship-native.sh` bumps `+B`)
- Release tags: `native-v<version>`; release checklist in `.claude/rules/release.md`
- Issue tracker: github, only through `scripts/gh-ops.sh` and `scripts/gh-file-issue.sh`
- Labels and workflow states: `.claude/process.md` (type, domain, delegation, shape)
- Domain labels, by keyword:
  - `touch`: touch, gesture, swipe, pinch, scroll
  - `ux`: ux, ui, layout, mobile, keyboard, panel
  - `security`: security, vault, credential, encrypt
  - `image`: image, sixel, kitty, iterm
  - `ios`: ios, iphone, ipad
- Version snapshot for issues: `scripts/gh-ops.sh version` prints the code hash and the app version the local server reports (`MOBISSH_PORT`, default 8081); flag a mismatch as a stale server
- Repro artifacts (attach only recent ones tied to the issue):
  - `test-results/uploads/`: bug-report bundles from the app (screenshot, telemetry rings)
  - `test-results/emulator-shots/`: screenshots from `scripts/emu-shot.sh`
  - `/tmp/mobissh/logs/`: `native-integration-suite.log`, logcat from `scripts/emu-log.sh`
  - long-press repro recordings: `scripts/assemble-repro.sh` turns the frame burst into frames
- Bot attempt log: `~/.claude/projects/-home-dev-workspace-mobissh/memory/bot-attempts.md`
- Infra needs:
  - fleet emulator lease: `scripts/with-fleet-emulator.sh -- <command>` (exclusive, shared with other fleet repos)
  - docker fixtures: `test-sshd` and `jump-target` from `docker-compose.test.yml`, on the `mobissh` docker network (`.claude/rules/server.md`)
  - mac-build: `scripts/mac-build-via-hub.sh` (native/MAC-BUILD.md)
  - CI-as-gate: `.github/workflows/ci.yml` runs the fast gate, eslint and semgrep
- Post-merge deploy: `scripts/container-ctl.sh restart` after a batch of merges; `scripts/container-ctl.sh ensure` before asking the owner to test anything

## Gates
- fast: scripts/native-fast-gate.sh
- full: scripts/native-fast-gate.sh && scripts/with-fleet-emulator.sh -- scripts/terminal-flow-gate.sh
  - needs: the terminal-flow step only where the terminal view, gesture routing, selection/gutter, the copy path, detection/anchors or `native/third_party/flterm/` changed; elsewhere `full` is the fast gate
  - needs: a fleet emulator lease (the step boots the leased device)
- device: scripts/with-fleet-emulator.sh -- scripts/native-fast-gate.sh --with-integration
  - needs: a fleet emulator lease; the suite enforces `native/integration_test/BASELINE.manifest` (`.claude/rules/testing.md`)
  - needs: required before merge when `scripts/integration-required.sh --stdin` exits 0 for the PR's file list; `scripts/gh-ops.sh integrate` refuses those PRs until re-run with `--integration-verified`
  - args: a subset instead of the whole suite: `scripts/with-fleet-emulator.sh -- scripts/integration-subset.sh integration_test/<name>_test.dart ...`
- ship: scripts/ship-native.sh --message-file F
  - args: F, the commit message file (write it with the Write tool)
  - needs: refuses on doc drift (`scripts/doc-drift.sh --block`)

## Doc surfaces
- env-prefix: MOBISSH_
- code: *.sh scripts/*.mjs scripts/*.py
- records: assessments/ test-history/ docs/announce/
- research: docs/*research*.md docs/emulator-test-overhaul.md docs/native-rewrite-lessons-from-pwa.md docs/resources/
- exclude: native/third_party/ .claude/skills/crystallize/tests/
- ignore: scripts/doc-drift-ignore.txt

## Layout
- `native/lib/`: the app. State is Riverpod providers.
  - `ssh/`: dartssh2 sessions, shell, SFTP, host-key store, jump host, `~/.ssh/config` parse/export
  - `services/`: the UI to foreground-task isolate gateway (`task_ssh_gateway.dart`; SSH runs in the task isolate), session host, keepalive, SFTP, link routing, self-update, attention notifications
  - `state/`: Riverpod providers (sessions, connections, profiles, keys, detection, UI prefs)
  - `storage/`: profile/key/favorite/detection stores, `secrets_store.dart`, encrypted backup (`backup.dart`)
  - `terminal/`: session stream parsing, tmux control mode, URL hit-testing
  - `ui/`: screens, sheets, the terminal view and its gutter/decorator layers, file viewers
  - `diagnostics/`: paint/frame stats, byte/gesture/connect traces, feedback bundle, crash reporter
- `native/third_party/flterm/`: vendored terminal widget fork; rendering goes through libghostty via FFI
- `native/test/`: headless unit and widget tests (fast gate); `native/integration_test/`: on-emulator tests
- `server/index.js`: Node.js on port 8081 (install page, artifacts, bug-report relay, approval bridge); it carries no SSH traffic
- `server-feedback/`: the feedback service the server relays to
- `test/infra/`: node:test coverage of the non-Flutter infrastructure

Design invariants: session work lives in the task isolate so connections survive
backgrounding (test it headless with `InMemoryGatewayPair`); libghostty damage is
single-consumption, so never add a second render-state consumer.
