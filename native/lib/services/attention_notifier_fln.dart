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
  unawaited(
    PendingFocusBridge(FftKeyValueStore()).setPendingFromPayload(payload),
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
    const initSettings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (response) {
        // Foreground tap (app alive): record pending focus; the UI consumes it
        // on the next resume. The background variant covers a dead app.
        unawaited(
          PendingFocusBridge(FftKeyValueStore())
              .setPendingFromPayload(response.payload),
        );
      },
      onDidReceiveBackgroundNotificationResponse:
          attentionNotificationTapBackground,
    );
    // Create the HIGH channel explicitly so importance is correct on first post.
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        kAttentionChannelId,
        kAttentionChannelName,
        description: kAttentionChannelDescription,
        importance: Importance.high,
      ),
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
