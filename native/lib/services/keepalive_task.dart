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
import 'attention_notifier_fln.dart';
import 'session_host.dart';
import 'session_messages.dart';
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
  KeepaliveTaskHandler({
    SessionHostBuilder? hostBuilder,
    TaskSideFftTransport? transportForTest,
  }) : _hostBuilder = hostBuilder ?? _defaultHostBuilder,
       // ignore: prefer_initializing_formals
       _transportForTest = transportForTest;

  final SessionHostBuilder _hostBuilder;

  /// Test-only transport seam (#731). When non-null, [onStart] binds the
  /// task-side gateway to THIS transport instead of constructing a fresh
  /// FFT-backed one — letting tests observe the task → UI payloads (e.g. the
  /// ready re-emit triggered by `uiHello`) without binding to platform statics.
  final TaskSideFftTransport? _transportForTest;
  TaskSideFftTransport? _transport;

  /// The task-side gateway built in [onStart]. Held so [onReceiveData] can
  /// re-emit [SshTaskReadyEvent] when a fresh UI gateway sends an
  /// [SshUiHelloCommand] (#731 — the service outlived the UI process and
  /// `onStart` won't re-fire).
  TaskSshGateway? _gateway;
  SessionHost? _host;

  /// Visible for testing — exposes the host owned by this handler so widget
  /// tests can drive it through the gateway pair.
  @visibleForTesting
  SessionHost? get hostForTest => _host;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    ctrace('task', 'onStart: building SessionHost + gateway');
    startedAt = timestamp;
    final transport = _transportForTest ?? TaskSideFftTransport();
    final gateway = TaskSideForegroundGateway(transport: transport);
    _transport = transport;
    _gateway = gateway;
    // The host announces readiness in its constructor (#539): the first
    // task → UI payload it sends is an `SshTaskReadyEvent`, which the UI-side
    // gateway uses to flush any commands buffered during isolate spin-up.
    _host = _hostBuilder(gateway);
    ctrace('task', 'onStart: host built (ready event should be sent)');
  }

  @override
  void onReceiveData(Object data) {
    // #731: a fresh UI gateway that bound to an already-running service sends an
    // `uiHello` (via `sendControl`, never buffered) to re-trigger the readiness
    // handshake that `onStart` would otherwise have sent. Re-emit
    // `SshTaskReadyEvent` so the new gateway flips ready and flushes its
    // buffered `connect`. Idempotent — harmless if the gateway is already ready.
    // Intercepted BEFORE forwarding so the host doesn't try to dispatch it as a
    // session command.
    final kind = data is Map ? (data['kind'] ?? data['type']) : null;
    if (kind == SshTaskCommandKind.uiHello.name) {
      ctrace('task', 'onReceiveData: uiHello → re-emitting ready (#731)');
      _gateway?.send(const SshTaskReadyEvent().toJson());
      return;
    }
    // Forward the UI-side payload into the gateway transport. The gateway
    // coerces shape; the host dispatches the command.
    final t = data is Map
        ? (data['kind'] ?? data['type'] ?? '?')
        : data.runtimeType;
    ctrace('task', 'onReceiveData: kind=$t transport=${_transport != null}');
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
    _gateway = null;
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

SessionHost _defaultHostBuilder(TaskSshGateway gateway) => SessionHost(
  gateway: gateway,
  // #840 Slice 2: post attention notifications from the task isolate (where the
  // AttentionSignalScanner runs and is always alive, so backgrounded sessions
  // still fire). Bound here — desktop/test hosts construct SessionHost without a
  // notifier, so they fall back to Slice-1 log-only behaviour.
  attentionNotifier: FlnAttentionNotifier(),
);

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

  /// Update the RUNNING foreground-service notification's title + text in place
  /// (#847). Called on every session-state transition so the persistent (LOW,
  /// silent) FGS notification reflects the live count instead of being frozen on
  /// the "Connecting…" text it was started with. `onlyAlertOnce: true` keeps the
  /// update SILENT (the plugin re-alerts on every update otherwise). A no-op when
  /// the service isn't running.
  Future<void> updateService({
    required String notificationTitle,
    required String notificationText,
  });

  Future<bool> stopService();
}

/// A connected session's identity for the FGS notification text (#847). Carries
/// just the human label fields so [keepaliveNotificationText] can render a
/// single connected session as `user@host`.
class KeepaliveSessionInfo {
  const KeepaliveSessionInfo({this.host, this.username});

  final String? host;
  final String? username;

  /// `user@host`, falling back to whichever part is known, or a generic phrase
  /// when neither is. Never leaks a port / auth material — host + user only.
  String get label {
    final h = (host != null && host!.isNotEmpty) ? host : null;
    final u = (username != null && username!.isNotEmpty) ? username : null;
    if (u != null && h != null) return '$u@$h';
    if (h != null) return h;
    if (u != null) return u;
    return 'session';
  }
}

/// Pure FGS-notification text mapper (#847). Drives the persistent foreground
/// service notification from the live session state so it never sits frozen on
/// "Connecting…" once a session is up. Priority order:
///   1. ANY session reconnecting → "Reconnecting… (N connected)".
///   2. 0 connected (handshaking / nothing up yet) → "Connecting…".
///   3. exactly 1 connected → "Connected — user@host".
///   4. N connected → "Connected — N sessions".
String keepaliveNotificationText({
  required int connectedCount,
  required bool anyReconnecting,
  KeepaliveSessionInfo? singleConnected,
}) {
  if (anyReconnecting) {
    return 'Reconnecting… ($connectedCount connected)';
  }
  if (connectedCount <= 0) {
    return 'Connecting…';
  }
  if (connectedCount == 1) {
    final label = singleConnected?.label ?? 'session';
    return 'Connected — $label';
  }
  return 'Connected — $connectedCount sessions';
}

/// Build the `ForegroundTaskOptions` we hand to `FlutterForegroundTask.init`.
///
/// Extracted so unit tests can assert on the configuration without binding to
/// platform method channels — in particular `allowWakeLock: true` is what
/// keeps the Dart isolate alive during Doze mode (#517). The actual wake-lock
/// acquisition happens natively (the plugin grabs a `PARTIAL_WAKE_LOCK` when
/// the foreground service starts); we can only assert here that the flag is
/// configured.
///
/// #738: `allowWifiLock: true` holds a `WifiManager.WifiLock` while the service
/// runs so the Wi-Fi radio does NOT power down during Doze. The CPU wake lock
/// alone keeps timers/CPU alive, but a sleeping Wi-Fi radio silently drops the
/// TCP/Tailscale socket even with the FGS running — that is the prime cause of
/// "sessions die during an ordinary screen-off sleep with no real network
/// loss." The platform-side lock acquisition is verified on a real device
/// (lock the phone with live sessions, wake → still connected); this builder
/// only asserts the flag is configured.
ForegroundTaskOptions buildKeepaliveTaskOptions() {
  return ForegroundTaskOptions(
    eventAction: ForegroundTaskEventAction.nothing(),
    autoRunOnBoot: false,
    autoRunOnMyPackageReplaced: false,
    allowWakeLock: true,
    allowWifiLock: true,
  );
}

/// No-op keep-alive gateway for desktop (macOS / Linux / Windows, #577).
///
/// `flutter_foreground_task` is an Android/iOS-only plugin: its method-channel
/// calls throw `MissingPluginException` on desktop. Desktop processes are not
/// killed by the OS, so no keep-alive service is needed — the SSH socket lives
/// in the in-process `SessionHost` for the lifetime of the app. This gateway
/// reports "initialized, never running" and treats start/stop as successful
/// no-ops so [KeepaliveController] short-circuits cleanly without ever touching
/// the FFT statics.
class NoopKeepaliveGateway implements KeepaliveGateway {
  const NoopKeepaliveGateway();

  @override
  bool get isInitialized => true;

  @override
  Future<bool> get isRunningService async => false;

  @override
  void init() {}

  @override
  Future<bool> startService({
    required String notificationTitle,
    required String notificationText,
  }) async => true;

  @override
  Future<void> updateService({
    required String notificationTitle,
    required String notificationText,
  }) async {}

  @override
  Future<bool> stopService() async => true;
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
  Future<void> updateService({
    required String notificationTitle,
    required String notificationText,
  }) async {
    // #847: re-render the running FGS notification's text in place. The channel
    // is `onlyAlertOnce: true` (set in init), so this is SILENT — no buzz on
    // every transition (the plugin re-alert bug). Tolerant of a missing plugin /
    // a not-running service: the plugin no-ops or throws MissingPluginException
    // off-Android, which we swallow so a desktop/test build can't crash here.
    try {
      await FlutterForegroundTask.updateService(
        notificationTitle: notificationTitle,
        notificationText: notificationText,
      );
    } catch (e) {
      ctrace('ui.keepalive', 'updateService failed — $e');
    }
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
    void Function()? onServiceAlreadyRunning,
  }) : _gateway = gateway ?? FlutterForegroundTaskGateway(),
       // ignore: prefer_initializing_formals
       _onServiceStopped = onServiceStopped,
       // ignore: prefer_initializing_formals
       _onServiceAlreadyRunning = onServiceAlreadyRunning {
    _enabled = enabled;
  }

  final KeepaliveGateway _gateway;

  /// Called after the foreground task isolate is actually stopped, so the
  /// UI↔task gateway can reset to not-ready and re-buffer commands until the
  /// next isolate generation re-handshakes (#564 reconnect fix).
  final void Function()? _onServiceStopped;

  /// Called when [_startIfStopped] finds the foreground service ALREADY running
  /// instead of starting it (#731). When the service outlived the UI process,
  /// the fresh UI gateway is stuck not-ready (no `onStart` → no ready event), so
  /// the provider wires this to re-handshake the gateway (send `uiHello` via
  /// `sendControl` + arm the gateway's timeout guard). No-op on the normal
  /// cold-start path where the service is started fresh.
  final void Function()? _onServiceAlreadyRunning;
  bool _enabled = true;
  int _connectedCount = 0;
  final Map<Object, StreamSubscription<SshSessionData>> _subscriptions = {};

  /// Latest observed [SshSessionData] per attached session (#847). Drives the
  /// informative FGS notification text: the controller already listens to every
  /// session's state stream for the connected-count, so it also keeps the most
  /// recent snapshot here and recomputes the notification text on each
  /// transition (count, host/user, reconnecting). Cleared on detach/dispose.
  final Map<Object, SshSessionData> _latestData = {};

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
    _latestData[session] = snapshot();
    var wasConnected = _holdsService(snapshot().state);
    if (wasConnected) {
      _connectedCount += 1;
      unawaited(_startIfStopped());
    }
    _subscriptions[session] = stream.listen((data) {
      // #847: keep the freshest snapshot so the FGS text reflects host/user +
      // reconnecting state, not just the count.
      _latestData[session] = data;
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
      // #847: on EVERY transition refresh the running FGS notification text so
      // it never sits frozen on "Connecting…" once a session is up (and shows
      // "Reconnecting…" mid-reconnect). Silent (onlyAlertOnce). No-op when the
      // service isn't running.
      unawaited(_refreshNotification());
    });
  }

  /// Build the live FGS notification text from the per-session snapshots (#847)
  /// and push it to the running service. Counts `connected` sessions, detects
  /// any `reconnecting`, and renders `user@host` for a lone connected session.
  /// A no-op when the service isn't running (start path renders its own text).
  Future<void> _refreshNotification() async {
    if (!_gateway.isInitialized) return;
    // When the count just dropped to zero the service is being (or has been)
    // stopped — do NOT race an `updateService` against that stop (it would
    // re-render "Connecting…" onto a notification that's going away, and clobber
    // the `stop`-last invariant existing tests assert). Only refresh while at
    // least one session still holds the service.
    if (_connectedCount == 0) return;
    if (!await _gateway.isRunningService) return;
    await _gateway.updateService(
      notificationTitle: 'MobiSSH',
      notificationText: _currentNotificationText(),
    );
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
    _latestData.remove(session);
    final (_, SshSessionData Function() snapshot) = _viewOf(session);
    if (_holdsService(snapshot().state)) {
      _connectedCount = (_connectedCount - 1).clamp(0, 1 << 30);
      if (_connectedCount == 0) await _stopIfRunning();
    }
    // #847: a remaining session may now be the lone connected one — refresh.
    await _refreshNotification();
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
    _latestData.clear();
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
      // #731: the service is up but a fresh UI gateway (after the FGS outlived
      // the UI process) is stuck not-ready because `onStart` won't re-fire.
      // Re-handshake so the buffered `connect` can flush instead of hanging
      // silently. Harmless when the gateway is already ready (the callback
      // guards on readiness).
      _onServiceAlreadyRunning?.call();
      return;
    }
    ctrace('ui.keepalive', '_startIfStopped: calling startService...');
    // #847: render the START text from the live snapshots too (not just the
    // raw count) so a service started AT the moment a session reaches connected
    // already shows "Connected — user@host" instead of "Connecting…".
    final ok = await _gateway.startService(
      notificationTitle: 'MobiSSH',
      notificationText: _currentNotificationText(),
    );
    ctrace('ui.keepalive', '_startIfStopped: startService → $ok');
    // Belt-and-suspenders (#847): if a `connected` transition raced the start
    // (service was mid-start when the listener fired and its refresh no-op'd
    // because isRunningService was still false), correct the text now.
    if (ok) await _refreshNotification();
  }

  /// Compute the live FGS notification text from the per-session snapshots
  /// (#847). Shared by the start path and [_refreshNotification].
  String _currentNotificationText() {
    var connected = 0;
    var anyReconnecting = false;
    KeepaliveSessionInfo? single;
    for (final data in _latestData.values) {
      if (data.state == SshSessionState.reconnecting) anyReconnecting = true;
      if (data.state == SshSessionState.connected) {
        connected += 1;
        single = KeepaliveSessionInfo(host: data.host, username: data.username);
      }
    }
    if (connected != 1) single = null;
    return keepaliveNotificationText(
      connectedCount: connected,
      anyReconnecting: anyReconnecting,
      singleConnected: single,
    );
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
