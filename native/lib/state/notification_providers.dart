// Riverpod wiring for tappable session notifications (#575).
//
// Two providers:
//   - [pendingFocusBridgeProvider] resolves the cross-isolate "session to
//     focus" hand-off. Production binds it to the foreground-task plugin's
//     persistent data store (survives process death → cold-start tap routing);
//     tests override it with an in-memory bridge.
//   - [notificationFocusRouterProvider] consumes the pending focus and calls
//     `sessionsProvider.notifier.setActive(sessionId)`. The UI calls
//     `consumePendingFocus()` on app init + on every `resumed` lifecycle event
//     so a tapped notification lands the user on the originating session.
//
// ignore_for_file: prefer_initializing_formals

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../diagnostics/connect_trace.dart';
import '../platform/desktop.dart';
import '../services/session_notification.dart';
import 'sessions.dart';

/// [KeyValueStore] backed by `FlutterForegroundTask.saveData/getData`. This
/// store is shared between the UI isolate and the foreground-task isolate AND
/// persists across process death, so a notification tapped while the app is
/// killed still records the originating session for the next cold start to
/// route. Android-only — desktop uses [MapKeyValueStore] (no FFT plugin).
class FftKeyValueStore implements KeyValueStore {
  const FftKeyValueStore();

  @override
  Future<String?> getString(String key) =>
      FlutterForegroundTask.getData<String>(key: key);

  @override
  Future<void> setString(String key, String value) =>
      FlutterForegroundTask.saveData(key: key, value: value);

  @override
  Future<void> remove(String key) => FlutterForegroundTask.removeData(key: key);
}

/// The pending-focus hand-off. Desktop (#577) has no FFT plugin and no task
/// isolate, so it gets an in-memory bridge (no real OS notifications there);
/// Android uses the persistent FFT-backed store. Tests override this provider.
final pendingFocusBridgeProvider = Provider<PendingFocusBridge>((ref) {
  final store = ref.watch(isDesktopProvider)
      ? MapKeyValueStore()
      : const FftKeyValueStore();
  return PendingFocusBridge(store);
});

/// Routes a tapped notification's pending sessionId to the active session.
class NotificationFocusRouter {
  NotificationFocusRouter({
    required PendingFocusBridge bridge,
    required void Function(String sessionId) focus,
  }) : _bridge = bridge,
       _focus = focus;

  final PendingFocusBridge _bridge;
  final void Function(String sessionId) _focus;

  /// Consume any pending focus (one-shot) and focus that session. No-op when
  /// nothing is pending. Safe when the sessionId is unknown — `setActive`
  /// itself is a no-op for an absent id. Called on app init + on `resumed`.
  Future<void> consumePendingFocus() async {
    final sessionId = await _bridge.takePending();
    if (sessionId == null) return;
    ctrace('ui.notif', 'consumePendingFocus → setActive($sessionId)');
    _focus(sessionId);
  }
}

/// App-wide router. Reads the bridge + the sessions notifier so a tapped
/// notification focuses the originating session.
final notificationFocusRouterProvider = Provider<NotificationFocusRouter>((
  ref,
) {
  return NotificationFocusRouter(
    bridge: ref.watch(pendingFocusBridgeProvider),
    focus: (sessionId) =>
        ref.read(sessionsProvider.notifier).setActive(sessionId),
  );
});
