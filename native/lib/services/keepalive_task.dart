// Background keep-alive for SSH sessions on Android (#512).
//
// When a session enters the `connected` state, start a foreground service so
// Android won't kill the process while the user swaps to another app. The
// service is stopped as soon as no session is connected.
//
// Single-session for now. TODO(#511): once multi-session lands, the
// `KeepaliveController` needs to track a *count* of connected sessions and
// only stop the service when the count drops to zero. The plumbing here is
// already counted-based (see `_connectedCount`) but only one session can be
// tracked through `attach()` until the session collection refactor lands.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../ssh/ssh_session.dart';

/// Top-level entry point for the foreground task isolate. Must be
/// `@pragma('vm:entry-point')` so the AOT compiler keeps it.
@pragma('vm:entry-point')
void startKeepaliveCallback() {
  FlutterForegroundTask.setTaskHandler(KeepaliveTaskHandler());
}

/// Minimal task handler — the wake lock on the foreground task is enough to
/// keep the Dart isolate (and the SSH socket on it) alive. We don't do any
/// periodic work; the running socket pump is the heartbeat.
class KeepaliveTaskHandler extends TaskHandler {
  DateTime? startedAt;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    startedAt = timestamp;
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Intentionally empty. The foreground service exists only to keep the
    // process alive; the SSH socket's own read loop handles I/O.
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    startedAt = null;
  }
}

/// Thin wrapper over the static `FlutterForegroundTask` API. Lets us inject a
/// fake in tests so we don't bind to platform method channels.
abstract class KeepaliveGateway {
  bool get isInitialized;

  Future<bool> get isRunningService;

  void init();

  Future<bool> startService({
    required String notificationTitle,
    required String notificationText,
  });

  Future<bool> stopService();
}

/// Default gateway that talks to the real `FlutterForegroundTask`.
class FlutterForegroundTaskGateway implements KeepaliveGateway {
  bool _initialized = false;

  @override
  bool get isInitialized => _initialized;

  @override
  Future<bool> get isRunningService => FlutterForegroundTask.isRunningService;

  @override
  void init() {
    if (_initialized) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'mobissh_keepalive',
        channelName: 'MobiSSH keep-alive',
        channelDescription:
            'Notification while at least one SSH session is connected.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
    _initialized = true;
  }

  @override
  Future<bool> startService({
    required String notificationTitle,
    required String notificationText,
  }) async {
    final result = await FlutterForegroundTask.startService(
      serviceTypes: const [ForegroundServiceTypes.dataSync],
      notificationTitle: notificationTitle,
      notificationText: notificationText,
      callback: startKeepaliveCallback,
    );
    return result is ServiceRequestSuccess;
  }

  @override
  Future<bool> stopService() async {
    final result = await FlutterForegroundTask.stopService();
    return result is ServiceRequestSuccess;
  }
}

/// Orchestrates start/stop of the foreground service in response to SSH
/// session lifecycle changes.
///
/// Tracking model (single-session for now, multi-ready):
///   - `attach(session)` registers a session whose state will be observed.
///   - The controller listens to that session's stream and bumps an internal
///     "connected count" up on `connected`, back down on any terminal state.
///   - When the count goes from 0 → ≥1 the service starts; when it returns
///     to 0 the service stops.
class KeepaliveController {
  KeepaliveController({
    KeepaliveGateway? gateway,
    bool enabled = true,
  }) : _gateway = gateway ?? FlutterForegroundTaskGateway() {
    _enabled = enabled;
  }

  final KeepaliveGateway _gateway;
  bool _enabled = true;
  int _connectedCount = 0;
  final Map<SshSessionController, StreamSubscription<SshSessionData>>
      _subscriptions = {};

  /// Whether the keep-alive service is allowed to run at all. Setting this
  /// to false stops a running service immediately; setting back to true
  /// starts it if any sessions are currently connected.
  bool get enabled => _enabled;
  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    if (!value) {
      // User disabled — drop the service even if sessions are still up.
      unawaited(_stopIfRunning());
    } else if (_connectedCount > 0) {
      unawaited(_startIfStopped());
    }
  }

  /// Current observed connected-session count. Visible for testing.
  @visibleForTesting
  int get connectedCount => _connectedCount;

  /// Begin observing the given session controller. Safe to call multiple
  /// times with the same controller.
  void attach(SshSessionController session) {
    if (_subscriptions.containsKey(session)) return;
    var wasConnected = session.data.state == SshSessionState.connected;
    if (wasConnected) {
      _connectedCount += 1;
      unawaited(_startIfStopped());
    }
    _subscriptions[session] = session.stream.listen((data) {
      final isConnected = data.state == SshSessionState.connected;
      if (isConnected && !wasConnected) {
        _connectedCount += 1;
        unawaited(_startIfStopped());
      } else if (!isConnected && wasConnected) {
        _connectedCount = (_connectedCount - 1).clamp(0, 1 << 30);
        if (_connectedCount == 0) unawaited(_stopIfRunning());
      }
      wasConnected = isConnected;
    });
  }

  /// Stop observing the given session controller. If it was connected, the
  /// connected count is decremented.
  Future<void> detach(SshSessionController session) async {
    final sub = _subscriptions.remove(session);
    if (sub == null) return;
    await sub.cancel();
    if (session.data.state == SshSessionState.connected) {
      _connectedCount = (_connectedCount - 1).clamp(0, 1 << 30);
      if (_connectedCount == 0) await _stopIfRunning();
    }
  }

  /// Release all session subscriptions and stop the service if running.
  Future<void> dispose() async {
    for (final sub in _subscriptions.values) {
      await sub.cancel();
    }
    _subscriptions.clear();
    _connectedCount = 0;
    await _stopIfRunning();
  }

  Future<void> _startIfStopped() async {
    if (!_enabled) return;
    if (!_gateway.isInitialized) _gateway.init();
    if (await _gateway.isRunningService) return;
    await _gateway.startService(
      notificationTitle: 'MobiSSH',
      notificationText: _connectedCount == 1
          ? '1 session connected'
          : '$_connectedCount sessions connected',
    );
  }

  Future<void> _stopIfRunning() async {
    if (!_gateway.isInitialized) return;
    if (!await _gateway.isRunningService) return;
    await _gateway.stopService();
  }
}
