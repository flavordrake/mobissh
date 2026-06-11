// UI-isolate notification-tap binding (#878).
//
// #878 root cause: `FlutterLocalNotificationsPlugin.initialize()` was called
// ONLY in the FGS task isolate (the posting side). On Android a plain
// notification tap launches/resumes MainActivity → the UI isolate's engine —
// and flutter_local_notifications delivers `onDidReceiveNotificationResponse`
// to the isolate that initialized the plugin IN THAT ENGINE. The UI isolate
// never initialized it, so the tap (and its payload) was silently dropped and
// the pending-focus write never happened — the root of the entire #857/#870
// wrong-host tap saga (those fixes were correct but downstream of a write that
// never occurred).
//
// This class is the PURE, unit-testable half of the fix: the platform wiring
// (`initializeAttentionFln` + `getNotificationAppLaunchDetails`, see
// `state/attention_providers.dart`) binds its two entry points to the real
// plugin callbacks; tests invoke them directly with payloads.
//
//   * [handleTap] — warm tap (app process alive): write pending via the bridge,
//     then IMMEDIATELY consume. The tap IS the resume — when the activity is
//     already resumed no later lifecycle event will fire, so waiting for one
//     (the pre-#878 contract) routes nothing.
//   * [seedColdStart] — process-death tap: the launch-details payload is seeded
//     as pending BEFORE the boot path's initial `consumePending()` runs, so the
//     existing cold-start consume (#840) routes it. Seeding does NOT consume —
//     boot owns the initial consume ordering.
//
// Telemetry flows through the injected [log] — production binds `clifecycle`
// (#766), whose durable 80-line ring survives connect-ring churn and ships in
// the feedback upload (bare `ctrace` in non-UI isolates is never uploaded).
// Logs sid/host only — never auth material.

import 'session_attention_notification.dart';

/// Pure seam between the UI-isolate FLN tap callbacks and the pending-focus
/// pipeline (#878). Injected bridge + consume keep it platform-free.
class AttentionUiTapBinding {
  AttentionUiTapBinding({
    required PendingFocusBridge bridge,
    required Future<String?> Function() consume,
    void Function(String where, String msg)? log,
  })  : _bridge = bridge,
        _consume = consume,
        _log = log;

  // Same pattern as attention_focus_router.dart: private fields from public
  // named params (no private named parameters in Dart).
  // ignore_for_file: prefer_initializing_formals
  final PendingFocusBridge _bridge;

  /// The router's `consumePending` (production:
  /// `ref.read(attentionFocusRouterProvider).consumePending`). Returns the
  /// focused sessionId or null. Injected so tests assert the immediate-consume
  /// wiring without Riverpod.
  final Future<String?> Function() _consume;

  /// Telemetry seam — production binds `clifecycle` so the tap path lands in
  /// the UPLOADED lifecycle ring (#766). Null in tests that don't assert logs.
  final void Function(String where, String msg)? _log;

  /// Warm tap (`onDidReceiveNotificationResponse` in the UI isolate): record
  /// the pending focus, then consume it IMMEDIATELY — the tap already resumed
  /// the activity, so no later lifecycle event will arrive to trigger the
  /// resume-path consume. Never throws (a tap must never crash the app).
  Future<void> handleTap(String? payload) async {
    final sid = AttentionNotification.parsePayload(payload).sessionId;
    _log?.call(
      'ui.attention',
      'tap: received sid=${sid ?? 'none'}'
      '${sid == null ? '' : ' host=${hostOfSessionId(sid)}'}',
    );
    // Write first (the bridge logs "pending set" + stamps the #870 seq) so even
    // a failed immediate consume leaves the pending for the next resume.
    await _bridge.setPendingFromPayload(payload);
    try {
      final focused = await _consume();
      _log?.call(
        'ui.attention',
        'tap: immediate consume → ${focused ?? 'none'}',
      );
    } catch (e) {
      _log?.call('ui.attention', 'tap: immediate consume failed: $e');
    }
  }

  /// Cold start: seed the launch-details payload as pending so the boot path's
  /// initial `consumePending()` (#840, RootRouter post-frame) routes it. Does
  /// NOT consume here — boot owns that ordering. Payload-less → no-op.
  Future<void> seedColdStart(String? payload) async {
    final sid = AttentionNotification.parsePayload(payload).sessionId;
    if (sid == null) {
      _log?.call('ui.attention', 'cold-start: launch details carried no sid');
      return;
    }
    _log?.call(
      'ui.attention',
      'cold-start: seeding pending sid=$sid host=${hostOfSessionId(sid)}',
    );
    await _bridge.setPendingFromPayload(payload);
  }
}
