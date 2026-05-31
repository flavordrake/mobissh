// Background keep-alive for SSH sessions on Android (#512, #531).
//
// When a session enters the `connected` state, start a foreground service so
// Android won't kill the process while the user swaps to another app. The
// service is stopped as soon as no session is connected.
//
// #531: the task handler that runs inside the foreground task's Dart isolate
// also owns a `SessionHost` so the underlying `SSHClient` instances live in
// the task isolate, not the UI isolate. If Android kills the UI isolate the
// socket survives; the UI proxy rebinds on resume.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../diagnostics/connect_trace.dart';
import '../ssh/ssh_session.dart';
import '../ssh/ssh_session_proxy.dart';
import 'session_host.dart';
import 'task_ssh_gateway.dart';

/// Top-level entry point for the foreground task isolate. Must be
/// `@pragma('vm:entry-point')` so the AOT compiler keeps it.
@pragma('vm:entry-point')
void startKeepaliveCallback() {
  FlutterForegroundTask.setTaskHandler(KeepaliveTaskHandler());
}

/// Task handler that runs inside the foreground task's Dart isolate (#531).
///
/// Hosts a [SessionHost] bound to a [TaskSideForegroundGateway]. Inbound
/// payloads arrive via [onReceiveData] (delivered by `flutter_foreground_task`
/// from the UI's `sendDataToTask` calls) and are routed into the gateway's
/// transport. Outbound payloads (state, output, snapshots) flow back via
/// `FlutterForegroundTask.sendDataToMain` inside the gateway's `send`.
class KeepaliveTaskHandler extends TaskHandler {
  DateTime? startedAt;

  /// Factory for the per-handler `SessionHost`. Production uses the default
  /// which constructs a real host wired to FFT static methods. Tests inject
  /// a stub host bound to a [StubFftTransport] so the wire contract can be
  /// exercised without binding to platform channels.
  KeepaliveTaskHandler({SessionHostBuilder? hostBuilder})
    : _hostBuilder = hostBuilder ?? _defaultHostBuilder;

  final SessionHostBuilder _hostBuilder;
  TaskSideFftTransport? _transport;
  SessionHost? _host;

  /// Visible for testing — exposes the host owned by this handler so widget
  /// tests can drive it through the gateway pair.
  @visibleForTesting
  SessionHost? get hostForTest => _host;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    ctrace('task', 'onStart: building SessionHost + gateway');
    startedAt = timestamp;
    final transport = TaskSideFftTransport();
    final gateway = TaskSideForegroundGateway(transport: transport);
    _transport = transport;
    // The host announces readiness in its constructor (#539): the first
    // task → UI payload it sends is an `SshTaskReadyEvent`, which the UI-side
    // gateway uses to flush any commands buffered during isolate spin-up.
    _host = _hostBuilder(gateway);
    ctrace('task', 'onStart: host built (ready event should be sent)');
  }

  @override
  void onReceiveData(Object data) {
    // Forward the UI-side payload into the gateway transport. The gateway
    // coerces shape; the host dispatches the command.
    final t = data is Map ? (data['type'] ?? '?') : data.runtimeType;
    ctrace('task', 'onReceiveData: type=$t transport=${_transport != null}');
    _transport?.deliver(data);
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Intentionally empty. The foreground service exists only to keep the
    // process alive; the SSH socket's own read loop handles I/O.
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    startedAt = null;
    final host = _host;
    _host = null;
    _transport = null;
    if (host != null) {
      // Tear down all hosted sessions cleanly (closes SSHClient + cancels
      // state subs). Errors here are swallowed — the isolate is going away.
      try {
        await host.dispose();
      } catch (_) {
        /* ignore */
      }
    }
  }
}

/// Factory injected for tests so a stub `SessionHost` can be hooked into
/// the [KeepaliveTaskHandler] without binding to FFT statics.
typedef SessionHostBuilder = SessionHost Function(TaskSshGateway gateway);

SessionHost _defaultHostBuilder(TaskSshGateway gateway) =>
    SessionHost(gateway: gateway);

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

/// Build the `ForegroundTaskOptions` we hand to `FlutterForegroundTask.init`.
///
/// Extracted so unit tests can assert on the configuration without binding to
/// platform method channels — in particular `allowWakeLock: true` is what
/// keeps the Dart isolate alive during Doze mode (#517). The actual wake-lock
/// acquisition happens natively (the plugin grabs a `PARTIAL_WAKE_LOCK` when
/// the foreground service starts); we can only assert here that the flag is
/// configured.
ForegroundTaskOptions buildKeepaliveTaskOptions() {
  return ForegroundTaskOptions(
    eventAction: ForegroundTaskEventAction.nothing(),
    autoRunOnBoot: false,
    autoRunOnMyPackageReplaced: false,
    allowWakeLock: true,
    allowWifiLock: false,
  );
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
      foregroundTaskOptions: buildKeepaliveTaskOptions(),
    );
    _initialized = true;
  }

  @override
  Future<bool> startService({
    required String notificationTitle,
    required String notificationText,
  }) async {
    // A foreground service of type `dataSync` cannot post its mandatory
    // ongoing notification on API 33+ without POST_NOTIFICATIONS. When the
    // permission is denied, `startService` returns a failure and the task
    // isolate never boots — the connect command stays buffered and the
    // session deadlocks at `idle` (#539). Request it (idempotent — no-op if
    // already granted) before starting. The plugin routes this to the OS
    // runtime-permission prompt the first time.
    try {
      final perm = await FlutterForegroundTask.checkNotificationPermission();
      if (perm != NotificationPermission.granted) {
        ctrace('ui.keepalive', 'requesting POST_NOTIFICATIONS (was $perm)');
        final result =
            await FlutterForegroundTask.requestNotificationPermission();
        ctrace('ui.keepalive', 'POST_NOTIFICATIONS → $result');
      }
    } catch (e) {
      ctrace('ui.keepalive', 'notification permission check failed — $e');
    }
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
    void Function()? onServiceStopped,
  }) : _gateway = gateway ?? FlutterForegroundTaskGateway(),
       // ignore: prefer_initializing_formals
       _onServiceStopped = onServiceStopped {
    _enabled = enabled;
  }

  final KeepaliveGateway _gateway;

  /// Called after the foreground task isolate is actually stopped, so the
  /// UI↔task gateway can reset to not-ready and re-buffer commands until the
  /// next isolate generation re-handshakes (#564 reconnect fix).
  final void Function()? _onServiceStopped;
  bool _enabled = true;
  int _connectedCount = 0;
  final Map<Object, StreamSubscription<SshSessionData>> _subscriptions = {};

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

  /// Returns true while the given state should hold the foreground service
  /// open. `reconnecting` (#517) is treated as "still connected" so Android
  /// doesn't freeze the Dart isolate mid-reconnect.
  ///
  /// This predicate drives the connected-COUNT (start on 0→1, stop on 1→0).
  /// The in-flight handshake states (`connecting`, `authenticating`,
  /// `awaitingHostKey`) deliberately do NOT increment the count — the service
  /// for those is started explicitly by [ensureStarted] on connect-initiation
  /// (#539). Because they never increment the count, they also never trigger
  /// the 1→0 stop, so a session mid-handshake cannot tear the service down.
  static bool _holdsService(SshSessionState state) {
    return state == SshSessionState.connected ||
        state == SshSessionState.reconnecting;
  }

  /// Start the foreground service immediately, independent of how many
  /// sessions are connected (#539). Called on connect-initiation so the task
  /// isolate (and its `SessionHost`) is running BEFORE the first connect
  /// command is dispatched across the gateway.
  ///
  /// Idempotent: guards on [KeepaliveGateway.isRunningService] so calling it
  /// twice does not start two services. A no-op when the user has disabled the
  /// keep-alive service.
  ///
  /// Tolerant of a missing platform plugin: on a platform where
  /// `flutter_foreground_task` isn't wired (e.g. the Flutter test host, or a
  /// desktop build) the underlying channel throws `MissingPluginException`.
  /// Connect-initiation must not crash on that, so the failure is caught and
  /// logged — the session still connects (just without the keep-alive service).
  Future<void> ensureStarted() async {
    ctrace('ui.keepalive', 'ensureStarted: begin');
    try {
      await _startIfStopped();
      ctrace('ui.keepalive', 'ensureStarted: done');
    } catch (e) {
      ctrace('ui.keepalive', 'ensureStarted: EXCEPTION — $e');
    }
  }

  /// Begin observing the given SSH session view (proxy or controller —
  /// anything that exposes a `data` snapshot + `stream` of `SshSessionData`).
  /// Safe to call multiple times with the same view.
  ///
  /// Accepts either an [SshSessionController] (used by tests + task-side
  /// code) or an [SshSessionProxy] (used by the UI consumer path post-#533).
  /// Both shapes expose the same fields by duck typing — the controller
  /// implements them explicitly, the proxy mirrors them from gateway events.
  void attach(Object session) {
    if (_subscriptions.containsKey(session)) return;
    final (Stream<SshSessionData> stream, SshSessionData Function() snapshot) =
        _viewOf(session);
    var wasConnected = _holdsService(snapshot().state);
    if (wasConnected) {
      _connectedCount += 1;
      unawaited(_startIfStopped());
    }
    _subscriptions[session] = stream.listen((data) {
      final isConnected = _holdsService(data.state);
      if (isConnected && !wasConnected) {
        _connectedCount += 1;
        unawaited(_startIfStopped());
      } else if (!isConnected && wasConnected) {
        _connectedCount = (_connectedCount - 1).clamp(0, 1 << 30);
        if (_connectedCount == 0) unawaited(_stopIfRunning());
      } else if (!isConnected &&
          _connectedCount == 0 &&
          _isTerminal(data.state)) {
        // #539: the service may have been started explicitly via
        // ensureStarted() before any session reached `connected` (count still
        // 0). If the connect then fails / disconnects, tear the service down
        // so it doesn't leak with no live sessions.
        unawaited(_stopIfRunning());
      }
      wasConnected = isConnected;
    });
  }

  /// A terminal session state: the connect attempt is over and not holding the
  /// service. Used to stop a service started by [ensureStarted] when the
  /// session never reached `connected`.
  static bool _isTerminal(SshSessionState state) {
    return state == SshSessionState.failed ||
        state == SshSessionState.disconnected;
  }

  /// Stop observing the given session. If it was connected, the connected
  /// count is decremented.
  Future<void> detach(Object session) async {
    final sub = _subscriptions.remove(session);
    if (sub == null) return;
    await sub.cancel();
    final (_, SshSessionData Function() snapshot) = _viewOf(session);
    if (_holdsService(snapshot().state)) {
      _connectedCount = (_connectedCount - 1).clamp(0, 1 << 30);
      if (_connectedCount == 0) await _stopIfRunning();
    }
  }

  /// Coerce a session-shaped object to the stream + snapshot pair. Avoids a
  /// shared abstract base class — the controller and proxy lifecycles are
  /// independent (controller lives in the task isolate, proxy in the UI
  /// isolate). Adding a common interface would force one to depend on the
  /// other's types, which we explicitly don't want.
  (Stream<SshSessionData>, SshSessionData Function()) _viewOf(Object session) {
    if (session is SshSessionController) {
      return (session.stream, () => session.data);
    }
    if (session is SshSessionProxy) {
      return (session.stream, () => session.data);
    }
    throw ArgumentError(
      'KeepaliveController.attach: unsupported session type ${session.runtimeType}',
    );
  }

  /// Release all session subscriptions and stop the service if running.
  Future<void> dispose() async {
    for (final sub in _subscriptions.values) {
      await sub.cancel();
    }
    _subscriptions.clear();
    _connectedCount = 0;
    // notifyGateway: false — on dispose the whole ProviderContainer is tearing
    // down, so reading taskSshGatewayProvider from the callback would throw
    // "provider read after dispose". The gateway is disposed alongside us; no
    // point resetting its readiness. Only runtime stops notify the gateway.
    await _stopIfRunning(notifyGateway: false);
  }

  Future<void> _startIfStopped() async {
    if (!_enabled) {
      ctrace('ui.keepalive', '_startIfStopped: disabled — skip');
      return;
    }
    if (!_gateway.isInitialized) {
      ctrace('ui.keepalive', '_startIfStopped: init()');
      _gateway.init();
    }
    final running = await _gateway.isRunningService;
    if (running) {
      ctrace('ui.keepalive', '_startIfStopped: already running — skip');
      return;
    }
    ctrace('ui.keepalive', '_startIfStopped: calling startService...');
    final ok = await _gateway.startService(
      notificationTitle: 'MobiSSH',
      notificationText: _connectedCount == 0
          ? 'Connecting…'
          : _connectedCount == 1
          ? '1 session connected'
          : '$_connectedCount sessions connected',
    );
    ctrace('ui.keepalive', '_startIfStopped: startService → $ok');
  }

  Future<void> _stopIfRunning({bool notifyGateway = true}) async {
    if (!_gateway.isInitialized) return;
    if (!await _gateway.isRunningService) return;
    await _gateway.stopService();
    // The task isolate is gone — tell the UI↔task gateway to re-buffer until a
    // fresh isolate re-handshakes, so a later reconnect isn't sent into the
    // void (#564). Skipped on dispose (container teardown — see dispose()).
    if (notifyGateway) _onServiceStopped?.call();
  }
}
