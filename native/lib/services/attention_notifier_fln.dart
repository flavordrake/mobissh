// Platform-binding attention notifier (#840, Slice 2).
//
// Binds the PURE [AttentionNotifier] / [KeyValueStore] seams (in
// session_attention_notification.dart) to the real plugins:
//
//   * `flutter_local_notifications` posts the HIGH-importance `mobissh_attention`
//     notification (loud, dismissible) from the FOREGROUND-TASK ISOLATE — the
//     isolate that runs the AttentionSignalScanner and is always alive, so a
//     backgrounded / non-active session still fires.
//   * `FlutterForegroundTask.saveData/getData/removeData` backs the
//     process-death-surviving [PendingFocusBridge] store (cold-start safe).
//
// The tap handler runs in a background isolate (`@pragma('vm:entry-point')`); it
// records the tapped notification's payload as pending focus, then the UI
// isolate consumes it on init / resume.
//
// This file binds platform channels, so it is NOT exercised by `flutter_test`
// unit runs (those inject the in-memory fakes). It is compiled by the gate and
// exercised on the emulator.

import 'dart:async';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../diagnostics/connect_trace.dart';
import 'session_attention_notification.dart';

/// Top-level background tap handler. Must be a top-level / static function with
/// `@pragma('vm:entry-point')` so the AOT compiler keeps it for the background
/// isolate the plugin spawns on tap.
@pragma('vm:entry-point')
void attentionNotificationTapBackground(NotificationResponse response) {
  // Best-effort: record the tapped payload so the UI isolate routes focus on
  // its next init/resume. Runs in a short-lived background isolate — keep it
  // tiny + tolerant.
  final payload = response.payload;
  // #870: bind the pending-WRITE log to `ctrace` so the write ORDER is visible
  // in a capture (this runs in a short-lived background isolate — its ctrace
  // ring is separate from the UI's, but logcat still shows it).
  unawaited(
    PendingFocusBridge(FftKeyValueStore(), log: ctrace)
        .setPendingFromPayload(payload),
  );
}

/// Shared FLN initialization (#878): the same `InitializationSettings` +
/// HIGH-importance `mobissh_attention` channel creation (idempotent on
/// Android), used by BOTH registrations so they can't drift:
///
///   * the FGS task isolate ([FlnAttentionNotifier._ensureInit]) — needed for
///     POSTING from the scanner's isolate;
///   * the UI isolate (`attentionUiFlnInitProvider` in
///     `state/attention_providers.dart`) — needed for TAP DELIVERY. On Android
///     a plain tap resumes MainActivity → the UI engine, and the plugin
///     delivers `onDidReceiveNotificationResponse` only to the isolate that
///     initialized it in that engine. Before #878 the UI isolate never did, so
///     every plain-tap payload was silently dropped (the #857/#870 root cause).
///
/// [onResponse] is the per-isolate tap callback; the background-ACTION handler
/// is always the shared top-level [attentionNotificationTapBackground].
Future<void> initializeAttentionFln(
  FlutterLocalNotificationsPlugin plugin, {
  required void Function(NotificationResponse response) onResponse,
}) async {
  const initSettings = InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
  );
  await plugin.initialize(
    initSettings,
    onDidReceiveNotificationResponse: onResponse,
    onDidReceiveBackgroundNotificationResponse:
        attentionNotificationTapBackground,
  );
  // Create the HIGH channel explicitly so importance is correct on first post.
  final android = plugin.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  await android?.createNotificationChannel(
    const AndroidNotificationChannel(
      kAttentionChannelId,
      kAttentionChannelName,
      description: kAttentionChannelDescription,
      importance: Importance.high,
    ),
  );
}

/// `flutter_local_notifications`-backed [AttentionNotifier].
///
/// Lazily initializes the plugin + the HIGH-importance `mobissh_attention`
/// Android channel on first use. Posting from the foreground-task isolate works
/// because the plugin only needs the app's notification context, which the FGS
/// already holds (POST_NOTIFICATIONS is granted via flutter_foreground_task at
/// service start — see keepalive_task.dart).
class FlnAttentionNotifier implements AttentionNotifier {
  FlnAttentionNotifier({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;

  Future<void> _ensureInit() async {
    if (_initialized) return;
    // #878: shared init (settings + channel) — see [initializeAttentionFln].
    // This task-isolate registration is what allows POSTING; tap DELIVERY for
    // plain taps happens via the UI isolate's registration
    // (`attentionUiFlnInitProvider`). This isolate's `onResponse` is kept as a
    // best-effort fallback for any response the platform still hands this
    // engine (e.g. a tap while the FGS engine is the one resumed).
    await initializeAttentionFln(
      _plugin,
      onResponse: (response) {
        // #870: bind the pending-WRITE log to `ctrace` so the write order is
        // captured.
        unawaited(
          PendingFocusBridge(FftKeyValueStore(), log: ctrace)
              .setPendingFromPayload(response.payload),
        );
      },
    );
    _initialized = true;
  }

  /// Stable integer notification id derived from the per-session tag so a repeat
  /// from the same session REPLACES (same id) rather than stacks.
  int _idFor(String tag) => tag.hashCode & 0x7fffffff;

  @override
  Future<void> post(AttentionNotification n) async {
    await _ensureInit();
    final details = AndroidNotificationDetails(
      kAttentionChannelId,
      kAttentionChannelName,
      channelDescription: kAttentionChannelDescription,
      importance: Importance.high,
      priority: Priority.high,
      tag: n.tag,
      autoCancel: true,
    );
    await _plugin.show(
      _idFor(n.tag),
      n.title,
      n.body,
      NotificationDetails(android: details),
      payload: n.payload,
    );
    ctrace('ui.attention', 'posted ${n.tag}');
  }

  @override
  Future<void> cancel(String sessionId) async {
    await _ensureInit();
    // #847: notifications are keyed per-HOST, so cancel the host's slot (a tap
    // / focus on any session to this host clears the one shared notification).
    final tag = 'mobissh.attention.${hostOfSessionId(sessionId)}';
    await _plugin.cancel(_idFor(tag), tag: tag);
  }
}

/// [KeyValueStore] backed by `FlutterForegroundTask.saveData/getData`. This
/// store survives process death (the plugin persists to disk), so a tap that
/// cold-starts the app still routes focus correctly.
class FftKeyValueStore implements KeyValueStore {
  const FftKeyValueStore();

  @override
  Future<String?> getString(String key) async {
    try {
      return await FlutterForegroundTask.getData<String>(key: key);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> setString(String key, String value) async {
    try {
      await FlutterForegroundTask.saveData(key: key, value: value);
    } catch (_) {
      /* ignore — focus routing is best-effort */
    }
  }

  @override
  Future<void> remove(String key) async {
    try {
      await FlutterForegroundTask.removeData(key: key);
    } catch (_) {
      /* ignore */
    }
  }
}
