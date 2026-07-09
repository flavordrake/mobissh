# mac-runner scripts (#1026)

Scripts in this directory are authored on fd-dev (Linux) and EXECUTED ONLY on
the runner Mac (matts-macbook-air). They mirror the Android emulator loop:

| Android (fd-dev) | Mac analog |
|---|---|
| `scripts/emulator-ctl.sh ensure` | `scripts/mac/sim-ctl.sh ensure` |
| `scripts/emu-shot.sh [label]` | `scripts/mac/sim-ctl.sh shot [label]` |
| `scripts/emu-log.sh` | `scripts/mac/sim-ctl.sh log [minutes]` |
| `scripts/native-connect-test.sh <file>` | `scripts/mac/mac-connect-test.sh <file> [--target ios\|macos]` |
| socat + `adb reverse` fixture bridge | socat hop to fd-dev's tailnet bridge |

The committed integration tests connect to `127.0.0.1:2222` / `testuser` /
`testpass` on every target. The Mac provides that address via a two-hop bridge
to the same Alpine test-sshd fixture:

```
Mac 127.0.0.1:2222 --socat--> fd-dev:2222 (tailnet) --socat--> test-sshd:22
```

The fd-dev half is `scripts/testsshd-tailnet-bridge.sh start` (binds fd-dev's
tailnet IP only — tailnet peers only, never 0.0.0.0). The Mac half is started
automatically by `mac-connect-test.sh`.

## Prerequisites (one-time Mac setup)

1. Full Xcode (not just CLI tools) from the App Store, then
   `sudo xcode-select -s /Applications/Xcode.app` and accept the license
   (`sudo xcodebuild -license accept`). Download the iOS platform:
   `xcodebuild -downloadPlatform iOS`.
2. Flutter SDK >= 3.44 (flterm floor) on PATH;
   `flutter config --enable-macos-desktop` (iOS is enabled by default on macOS
   hosts). `flutter doctor` clean for the darwin toolchains.
3. `brew install socat`.
4. Tailscale up and on the same tailnet as fd-dev (`tailscale status` shows
   `fd-dev`). MagicDNS on, or export `FDDEV_HOST=<fd-dev tailnet IP>`.
5. Agent-hub enrollment: register a `mac-runner` identity on the agent-hub
   agent-mail server so fd-dev can dispatch jobs and receive results
   (see memory `reference_agent_mail_hub_identity` on fd-dev).
6. This repo cloned; `cd native && flutter pub get`.

## First green run (sequence from the #1026 design)

macOS desktop first — no simulator, no signing; it also burns down the
"libghostty dylib survives codesigning" risk from #1012:

```
# on fd-dev
scripts/testsshd-tailnet-bridge.sh start

# on the Mac, repo root
scripts/mac/mac-connect-test.sh integration_test/connect_smoke_test.dart --target macos
```

Then the iOS Simulator (verifies the ios-simulator libghostty slice — free, no
Apple account):

```
scripts/mac/sim-ctl.sh ensure
scripts/mac/mac-connect-test.sh integration_test/connect_smoke_test.dart --target ios
```

Debug loop helpers: `sim-ctl.sh shot <label>` (PNG under
`test-results/simulator-shots/`, path on stdout) and `sim-ctl.sh log [minutes]`
(unified log filtered to the Runner process, path on stdout).

## Honest status

These scripts have never executed on a Mac (none is enrolled yet). They are
validated by `bash -n` only; expect first-contact fixes (simctl output parsing,
runtime naming) on the first real run.
