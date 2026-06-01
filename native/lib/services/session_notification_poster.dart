// Posts tappable session notifications from the foreground-task isolate (#575).
//
// The task isolate owns the single foreground-service notification and is the
// only place the notification tap (`TaskHandler.onNotificationPressed`) is
// delivered. So session-event notifications are surfaced by UPDATING that
// notification's title/body to the event content and recording the originating
// sessionId in a [PendingFocusBridge]. When the user taps it, the handler reads
// back that sessionId, persists it as the "pending focus", and launches the app
// — the UI isolate routes to that session on resume.
//
// This module is the seam between the pure [SessionNotification] builder and
// the platform. Production binds [post] to `FlutterForegroundTask.updateService`
// and [bridge] to the FFT-backed store; tests inject fakes so the wiring is
// exercised without platform channels.
//
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'session_notification.dart';

/// Platform sink for an updated notification. Production wires this to
/// `FlutterForegroundTask.updateService(notificationTitle:, notificationText:)`.
typedef NotificationUpdater =
    Future<void> Function({required String title, required String text});

/// Brings the app to the foreground. Production wires this to
/// `FlutterForegroundTask.launchApp()`.
typedef AppLauncher = void Function();

/// Surfaces session signals as the (single) foreground-service notification and
/// owns the tap → pending-focus hand-off.
class SessionNotificationPoster {
  SessionNotificationPoster({
    required PendingFocusBridge bridge,
    required NotificationUpdater update,
    required AppLauncher launch,
  }) : _bridge = bridge,
       _update = update,
       _launch = launch;

  final PendingFocusBridge _bridge;
  final NotificationUpdater _update;
  final AppLauncher _launch;

  /// The sessionId of the most recently posted notification — the session the
  /// notification currently points at. A tap routes here.
  String? _lastSessionId;

  /// Visible for tests.
  String? get lastSessionId => _lastSessionId;

  /// Surface a signal for [sessionId] (its human [label]). Updates the
  /// foreground notification and remembers the session so a tap routes to it.
  Future<void> notify({
    required String sessionId,
    required String label,
    required SessionSignalKind kind,
    String? message,
  }) async {
    final n = SessionNotification.build(
      sessionId: sessionId,
      label: label,
      kind: kind,
      message: message,
    );
    _lastSessionId = sessionId;
    await _update(title: n.title, text: n.body);
  }

  /// Called when the notification is tapped. Records the originating session as
  /// the pending focus (so the UI isolate focuses it on resume) and brings the
  /// app to the foreground. No-op when nothing has been posted yet.
  Future<void> onTapped() async {
    final sessionId = _lastSessionId;
    if (sessionId != null) {
      await _bridge.setPending(sessionId);
    }
    _launch();
  }
}
