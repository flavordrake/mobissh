# MobiSSH Native (Flutter / Android)

Native Android client for MobiSSH — Flutter port of the PWA tracked by [#501].

## Phase status

- [x] **Phase 0** — Flutter scaffold + release signing wired (commit `96a7289`).
- [x] **Phase 1** — `dartssh2` lifecycle: connect form, host-key prompt,
      password + key auth, banner capture, state machine. **No terminal yet.**
- [ ] Phase 2 — `xterm.dart` widget + shell session.
- [ ] Phase 3 — Profiles + `flutter_secure_storage` + `local_auth`.
- [ ] Phase 4 — Foreground service holding the SSH session.
- [ ] Phase 5 — Port-forward UI (`forwardLocal` / `forwardRemote`).
- [ ] Phase 6 — Polish + device testing + sideload pipeline.

## Running locally

All Flutter invocations go through the wrapper that fixes the dev container's
XDG path:

```bash
scripts/flutter-cmd.sh --in native pub get
scripts/flutter-cmd.sh --in native analyze
scripts/flutter-cmd.sh --in native test
```

The fast gate runs analyze + unit tests:

```bash
scripts/native-fast-gate.sh
```

## Phase 1 — connecting to test-sshd

The integration test exercises the full lifecycle against the real
`test-sshd` Alpine + OpenSSH container shared with the PWA tests.

### Prerequisites

The fd-dev container must share the `mobissh` Docker network so it can reach
`test-sshd:22` by DNS. The test-sshd lifecycle helper
(`tests/emulator/sshd-fixture.js`) handles this for headless tests; for the
Flutter integration test you start the container manually from the repo root:

```bash
docker compose -f docker-compose.test.yml up -d test-sshd
```

That command also creates the `mobissh` Docker network if needed. The fd-dev
container is joined to the network on first invocation of any fixture script,
or manually with:

```bash
docker network create mobissh   # idempotent
docker network connect mobissh $(hostname)
```

### Running the integration test

The integration tests are tagged `integration` so they don't run as part of
the default unit-only suite:

```bash
scripts/flutter-cmd.sh --in native test --tags integration \
  test/ssh_connect_integration_test.dart
```

Override host/port for non-container environments:

```bash
SSHD_HOST=localhost SSHD_PORT=2222 \
  scripts/flutter-cmd.sh --in native test --tags integration \
  test/ssh_connect_integration_test.dart
```

The test asserts:

- State transitions `connecting -> awaitingHostKey -> authenticating -> connected`.
- `remoteVersion` is populated and contains `SSH-`.
- The host-key store now trusts the server's fingerprint.
- A subsequent `disconnect()` lands in `disconnected`.
- Rejecting the host-key prompt lands in `failed`.

### Manual smoke test on the device

With the test-sshd container running and the fd-dev container joined to the
`mobissh` network, launching the Phase 1 app shows a connect form pre-filled
for `testuser@test-sshd:22` with password `testpass`. Tap **Connect**, accept
the host-key prompt, and the status panel reports
`State: connected`, plus the server's SSH version line.

## Architecture (Phase 1)

```
lib/
  main.dart                     — ProviderScope + Scaffold + connect form + status panel
  ssh/
    ssh_connect_params.dart     — host/port/username + sealed SshAuth.{password,key}
    ssh_session.dart            — SshSessionController + state machine + dartssh2 glue
    host_key_store.dart         — in-memory trust map (Phase 3: flutter_secure_storage)
  state/
    connection_providers.dart   — Riverpod providers wrapping the controller
  ui/
    connect_form.dart           — host/port/user/pass form, password|key toggle
    host_key_dialog.dart        — fingerprint confirmation dialog
test/
  host_key_store_test.dart      — pure unit
  ssh_session_test.dart         — state-machine transitions w/ fake sockets
  ssh_connect_integration_test.dart — `@Tags(['integration'])` real test-sshd
```

`SshSessionController` is constructed with optional `socketOpener` and
`hostKeyStore` arguments so unit tests can swap them out. The default opener
uses `SSHSocket.connect`; the default store is a fresh in-memory `HostKeyStore`.

[#501]: https://github.com/flavordrake/mobissh/issues/501
