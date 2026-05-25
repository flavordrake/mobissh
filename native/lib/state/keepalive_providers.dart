// Riverpod wiring for the background keep-alive service (#512).
//
// `keepaliveEnabledProvider` exposes the user-facing toggle (persisted via
// SharedPreferences). `keepaliveControllerProvider` lazily constructs the
// `KeepaliveController` and attaches it to the SSH session controller.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/keepalive_task.dart';
import 'connection_providers.dart';

/// SharedPreferences key. Matches the PWA's localStorage key naming style.
const String keepaliveEnabledPrefKey = 'mobissh.keepalive.enabled';

/// Default-on, matching the PWA where the "Keep alive in background"
/// notification is enabled out of the box.
const bool keepaliveEnabledDefault = true;

/// User toggle for the keep-alive foreground service. Synchronous value
/// (defaulted to [keepaliveEnabledDefault] while we load preferences) so the
/// UI doesn't have to handle a loading state. Mutations persist via
/// SharedPreferences and propagate to the `KeepaliveController`.
class KeepaliveEnabledNotifier extends StateNotifier<bool> {
  KeepaliveEnabledNotifier({Future<SharedPreferences>? prefs})
      : _prefs = prefs ?? SharedPreferences.getInstance(),
        super(keepaliveEnabledDefault) {
    _hydrate();
  }

  final Future<SharedPreferences> _prefs;

  Future<void> _hydrate() async {
    try {
      final prefs = await _prefs;
      final stored = prefs.getBool(keepaliveEnabledPrefKey);
      if (stored != null && stored != state) state = stored;
    } catch (_) {
      // SharedPreferences may be unavailable under tests without bindings;
      // keep the default in that case.
    }
  }

  Future<void> set(bool value) async {
    state = value;
    try {
      final prefs = await _prefs;
      await prefs.setBool(keepaliveEnabledPrefKey, value);
    } catch (_) {
      // best-effort persistence
    }
  }
}

final keepaliveEnabledProvider =
    StateNotifierProvider<KeepaliveEnabledNotifier, bool>((ref) {
  return KeepaliveEnabledNotifier();
});

/// Singleton KeepaliveController, attached to the active session's proxy
/// (#533 — was the in-UI controller; sessions now run task-side via
/// [SshSessionProxy]). Recreated only when the provider container is
/// disposed.
final keepaliveControllerProvider = Provider<KeepaliveController>((ref) {
  final proxy = ref.watch(sshSessionProxyProvider);
  final controller = KeepaliveController(
    enabled: ref.read(keepaliveEnabledProvider),
  );
  controller.attach(proxy);
  // Mirror toggle changes into the controller.
  ref.listen<bool>(keepaliveEnabledProvider, (_, next) {
    controller.enabled = next;
  });
  ref.onDispose(() => controller.dispose());
  return controller;
});

/// Function the session collection calls to start the foreground task isolate
/// on connect-initiation (#539). Returns a `Future<void>`-producing callback so
/// `SessionsNotifier.addOrActivate` can `ensureStarted()` BEFORE the caller
/// dispatches the first connect command across the gateway.
///
/// This is a SEPARATE provider from [keepaliveControllerProvider] on purpose:
/// the lifecycle controller watches `sshSessionProxyProvider` →
/// `activeSessionEntryProvider` → `sessionsProvider`, so reading it from inside
/// the `SessionsNotifier` during a state mutation would create a provider read
/// cycle. The starter's controller does NOT observe any session, so the read is
/// acyclic. `startService` is idempotent (guards on `isRunningService`), so the
/// starter and the lifecycle controller never double-start the service; STOP
/// remains owned by the lifecycle controller's connected-count.
typedef KeepaliveStarter = Future<void> Function();

final keepaliveServiceStarterProvider = Provider<KeepaliveStarter>((ref) {
  final controller = KeepaliveController(
    enabled: ref.read(keepaliveEnabledProvider),
  );
  ref.listen<bool>(keepaliveEnabledProvider, (_, next) {
    controller.enabled = next;
  });
  ref.onDispose(controller.dispose);
  return controller.ensureStarted;
});
