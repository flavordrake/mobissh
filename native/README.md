# MobiSSH native app

The Flutter app: the product. What it does for users is in the root [README.md](../README.md); building, testing and diagnostics are in [developer.md](../developer.md).

## Layout

```
lib/
  main.dart      app bootstrap, crash-report flush, deep-link and update wiring
  ssh/           dartssh2 sessions, host keys, jump hosts, SFTP, ssh_config import/export
  services/      session host (task isolate), keep-alive service, attention signals,
                 link routing and browsers, self-update, port forwarding
  state/         Riverpod providers (sessions, settings, detection, UI prefs)
  storage/       profiles, secure secrets, key library, favorites, encrypted backup
  terminal/      session stream parser, URL hit testing
  ui/            screens, the libghostty terminal view and gesture router, keybar,
                 compose bar, file browser and viewers, settings, Detection Lab
  diagnostics/   feedback bundle, crash reporter, telemetry rings
  platform/      desktop platform seam
  util/          small helpers
third_party/flterm/   vendored terminal fork rendering through libghostty (FFI)
test/                 headless unit and widget tests (fast gate)
integration_test/     on-device tests, gated by BASELINE.manifest
```

## Running

Every Flutter call goes through `scripts/flutter-cmd.sh`, which fixes the dev container's XDG paths:

```bash
scripts/flutter-cmd.sh --in native pub get
scripts/flutter-cmd.sh --in native analyze
scripts/flutter-cmd.sh --in native test --exclude-tags integration
```

`scripts/native-fast-gate.sh` runs the whole fast gate. The on-device tier, the test SSH server and the release builds are covered in [developer.md](../developer.md); desktop targets in [DESKTOP.md](DESKTOP.md) and [MAC-BUILD.md](MAC-BUILD.md).
