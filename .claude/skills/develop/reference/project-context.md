# MobiSSH Project Context

## What This Is
Mobile-first SSH client: a Flutter app (`native/`) that speaks SSH directly via
dartssh2, used over Tailscale. The retired PWA (#1205) is still the UX spec the app
duplicates; its code lives only in git history.

## Layout
- `native/lib/` — the app (the product). State is Riverpod providers.
  - `ssh/` — dartssh2 sessions, shell, SFTP, host-key store, jump host, `~/.ssh/config` parse/export
  - `services/` — the UI ↔ foreground-task isolate gateway (`task_ssh_gateway.dart`; SSH runs in the task isolate), session host, keepalive, SFTP download/fetchers, link routing, self-update, attention notifications
  - `state/` — Riverpod providers (sessions, connections, profiles, keys, detection, UI prefs)
  - `storage/` — profiles/keys/favorites/detection stores, `secrets_store.dart` (flutter_secure_storage), encrypted backup (`backup.dart`)
  - `terminal/` — session stream parsing, URL hit-testing
  - `ui/` — screens, sheets, terminal view and its gutter/decorator layers, file viewers
  - `diagnostics/` — paint/frame stats, byte/gesture/connect traces, feedback bundle, crash reporter
  - `platform/`, `util/` — desktop glue, small helpers
- `native/third_party/flterm` — vendored terminal widget fork; rendering goes through libghostty via FFI
- `native/test/` — headless unit + widget tests (fast gate); `native/integration_test/` — on-emulator tests (see `.claude/rules/testing.md`)
- `server/index.js` — Node.js on port 8081: static install page + APK/macOS artifacts, bug-report/telemetry relay, Claude Code approval bridge. It does not carry SSH traffic.
- `server-feedback/` — the feedback service the server relays to
- `test/infra/` — node:test coverage of the non-Flutter infrastructure

## Key Design Decisions
- Secrets never in plaintext: `flutter_secure_storage` or not stored (`.claude/rules/security.md`)
- Session work lives in the foreground-task isolate so connections survive backgrounding; the UI talks to it over the gateway (test with `InMemoryGatewayPair`)
- libghostty damage is single-consumption: never add a second render-state consumer
- `Cache-Control: no-store` on all server static responses
