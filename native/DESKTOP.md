# MobiSSH Desktop (macOS / Linux) — #577

The native Flutter app runs on the desktop in addition to Android. On desktop
there is **no WebSocket bridge and no foreground service** — SSH connects
directly.

## Why desktop is different from Android

| Concern | Android | Desktop (macOS / Linux / Windows) |
|---------|---------|-----------------------------------|
| SSH transport | dartssh2 over dart:io | dartssh2 over dart:io (same) |
| WS bridge | not used | not used |
| SessionHost location | foreground-task isolate (survives UI-isolate kill) | **in-process** (OS never kills the process) |
| Keep-alive service | `flutter_foreground_task` | **no-op** (`NoopKeepaliveGateway`) |
| Credential vault | flutter_secure_storage (Android Keystore) | flutter_secure_storage (macOS Keychain / libsecret on Linux) |

The platform split is driven by `isDesktopProvider` (see
`lib/platform/desktop.dart`). On desktop, `taskSshGatewayProvider`
(`lib/state/session_host_providers.dart`) builds an `InMemoryGatewayPair` and
hosts a live `SessionHost` on its task side in the same isolate, returning the
UI side. This reuses the exact in-process path the unit tests exercise — SSH
runs in the same isolate, which is fine on desktop because the OS doesn't kill
it. **SSH is direct over dart:io — no bridge.**

## Run on macOS (owner's Mac — needs Xcode)

The repo already contains `macos/` runner scaffolding (committed). If it is ever
absent, regenerate with `flutter create --platforms=macos .`.

```sh
# one-time: enable the desktop target for your Flutter install
flutter config --enable-macos-desktop

# from native/
flutter pub get
flutter run -d macos
```

To produce a release bundle: `flutter build macos` (outputs
`build/macos/Build/Products/Release/mobissh.app`).

### Entitlements

`macos/Runner/DebugProfile.entitlements` and `Release.entitlements` declare:

- `com.apple.security.app-sandbox` — sandboxed (App Store / notarization ready).
- `com.apple.security.network.client` — **outbound SSH** (dartssh2 connects out).
- `keychain-access-groups` = `$(AppIdentifierPrefix)com.flavordrake.mobissh` —
  flutter_secure_storage persists the credential vault in the macOS Keychain;
  a sandboxed app must declare its keychain access group.
- `com.apple.security.network.server` (Debug/Profile only) — Flutter's debug VM
  service / DDS runs a local server; not present in Release.

If you change the bundle identifier in
`macos/Runner/Configs/AppInfo.xcconfig`, update the `keychain-access-groups`
entry to match.

## Run on Linux (validation / CI build host)

Linux is the in-container de-risking gate: it shares ~all of the desktop code
path with macOS but builds without Xcode.

```sh
# system build deps (Ubuntu/Debian): GTK toolchain + libsecret for the vault
sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev

flutter config --enable-linux-desktop
flutter build linux          # → build/linux/x64/release/bundle/mobissh
# or: flutter run -d linux
```

`libsecret-1-dev` is required because `flutter_secure_storage_linux` stores the
vault via libsecret (the Linux Secret Service). macOS uses the Keychain instead
and needs no extra system package.
