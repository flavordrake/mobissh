// Riverpod wiring for the background keep-alive service (#512).
//
// `keepaliveEnabledProvider` exposes the user-facing toggle (persisted via
// SharedPreferences). `keepaliveControllerProvider` lazily constructs the
// `KeepaliveController` and attaches it to every session in the collection.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../platform/desktop.dart';
import '../services/keepalive_task.dart';
import 'session_host_providers.dart';
import 'sessions.dart';

/// Selects the keep-alive gateway for the current platform (#577). Desktop has
/// no foreground service (the process persists), so it uses a no-op gateway;
/// Android uses the real `flutter_foreground_task`-backed gateway. Reading this
/// keeps the FFT statics out of the desktop code path entirely.
KeepaliveGateway _keepaliveGatewayFor(Ref ref) {
  return ref.watch(isDesktopProvider)
      ? const NoopKeepaliveGateway()
      : FlutterForegroundTaskGateway();
}

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

/// Singleton KeepaliveController, attached to EVERY session in the collection.
///
/// Multi-session correctness: this provider used to `ref.watch` the active
/// session's proxy, which made it rebuild whenever the active session
/// changed. The old controller's `dispose` calls `_stopIfRunning` → stops the
/// foreground service → `onDestroy` disposes the task-side session host →
/// every hosted session emits `SshClosedEvent`. The result: starting a second
/// session terminated the first one mid-handshake (and the second along with
/// it). The fix is to keep ONE controller for the container's lifetime and
/// reconcile its attached subscriptions as sessions come and go — the
/// controller's `_connectedCount` already supports multiple concurrent
/// sessions; only the wiring was single-session.
final keepaliveControllerProvider = Provider<KeepaliveController>((ref) {
  final controller = KeepaliveController(
    gateway: _keepaliveGatewayFor(ref),
    enabled: ref.read(keepaliveEnabledProvider),
    onServiceStopped: () =>
        ref.read(taskSshGatewayProvider).markServiceStopped(),
  );
  // Initial attach for whatever sessions already exist when this controller
  // is first read (typically zero on cold start, but the proxy/session
  // collection survives provider container teardown in some flows).
  final initialIds = <String>{};
  for (final e in ref.read(sessionsProvider).entries) {
    controller.attach(e.proxy);
    initialIds.add(e.id);
  }
  // Reconcile attach/detach as sessions are added or closed. ref.listen
  // (vs watch) means this provider itself is NOT rebuilt on session-list
  // changes — the controller and the service it owns stay alive.
  final attached = initialIds;
  ref.listen<SessionsState>(sessionsProvider, (prev, next) {
    final nextIds = <String, SessionEntry>{
      for (final e in next.entries) e.id: e,
    };
    // Detach sessions that were removed.
    for (final id in attached.toList()) {
      if (!nextIds.containsKey(id)) {
        // Find the proxy from the prev list (it's gone from next).
        final removed = prev?.entries.where((e) => e.id == id).toList();
        if (removed != null && removed.isNotEmpty) {
          unawaited(controller.detach(removed.first.proxy));
        }
        attached.remove(id);
      }
    }
    // Attach newly added sessions.
    for (final entry in nextIds.entries) {
      if (!attached.contains(entry.key)) {
        controller.attach(entry.value.proxy);
        attached.add(entry.key);
      }
    }
  });
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
  // The starter only ever START the service (idempotently). STOP is owned by
  // [keepaliveControllerProvider]'s connected-count, so this controller holds
  // no session subscriptions and must NOT be disposed here — `dispose()` would
  // call `stopService()`, tearing down a service the lifecycle controller still
  // wants running.
  final controller = KeepaliveController(
    gateway: _keepaliveGatewayFor(ref),
    enabled: ref.read(keepaliveEnabledProvider),
    onServiceStopped: () =>
        ref.read(taskSshGatewayProvider).markServiceStopped(),
  );
  ref.listen<bool>(keepaliveEnabledProvider, (_, next) {
    controller.enabled = next;
  });
  return controller.ensureStarted;
});
