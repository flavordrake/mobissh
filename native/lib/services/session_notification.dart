// Meaningful OS notifications for SSH sessions (#575).
//
// When a remote process in a session signals "ready for review" or the session
// stops/disconnects, we surface a tappable Android notification whose tap
// returns the user to the EXACT originating session.
//
// This module owns the two PURE, headless-testable pieces of that path:
//
//   1. [SessionNotification] — maps a session event (its human label + a signal
//      kind + an optional message) to the notification's title/body, the
//      sessionId payload the tap carries, and a per-session tag so repeated
//      signals from one session REPLACE rather than stack (PWA notification-tag
//      parity).
//
//   2. [PendingFocusBridge] — the cross-isolate hand-off. The notification tap
//      is delivered to the foreground-task isolate (`TaskHandler
//      .onNotificationPressed`); it records the originating sessionId here and
//      launches the app. The UI isolate reads + clears it on resume/init and
//      calls `sessionsProvider.notifier.setActive(sessionId)`. The bridge is
//      abstracted over a [KeyValueStore] seam so production wires it to
//      `FlutterForegroundTask.saveData/getData` (which survives process death,
//      covering the cold-start case) while tests use an in-memory map.
//
// SECURITY: a notification only ever carries the session LABEL (user@host:port
// or profile title), a fixed human phrase, and the opaque sessionId. It never
// carries auth material — see the "no secret material" test.

import 'dart:async';

/// What a remote signal meant. Mapped from the session lifecycle / PTY signal
/// into a human notification phrase.
enum SessionSignalKind {
  /// The remote signalled it is ready for the user (e.g. OSC 9 / a long-running
  /// command finished, or the shell re-attached after a reconnect).
  ready,

  /// The session stopped — disconnected, failed, or the keep-alive service was
  /// torn down.
  stopped,
}

/// An immutable description of a tappable session notification. Pure data —
/// the platform posting happens elsewhere (the foreground-task isolate updates
/// its service notification with these fields).
class SessionNotification {
  const SessionNotification({
    required this.title,
    required this.body,
    required this.payload,
    required this.tag,
  });

  /// Notification title — the session's human label (user@host:port or the
  /// saved profile title).
  final String title;

  /// Notification body — the human meaning of the signal.
  final String body;

  /// Opaque payload carried by the notification so the tap can route back to
  /// the originating session. It is exactly the sessionId.
  final String payload;

  /// Android notification tag. Keyed by sessionId so a later signal from the
  /// same session REPLACES the prior notification instead of stacking, while
  /// distinct sessions get distinct tags (PWA notification-tag parity).
  final String tag;

  /// Tag prefix so the session notification never collides with the
  /// foreground-service keep-alive notification.
  static const String _tagPrefix = 'mobissh.session.';

  /// Build a notification description for [sessionId] (its [label]) given the
  /// [kind] of signal. An optional [message] (the parsed remote text, e.g. the
  /// OSC-9 message) is appended to the body when present.
  static SessionNotification build({
    required String sessionId,
    required String label,
    required SessionSignalKind kind,
    String? message,
  }) {
    final base = switch (kind) {
      SessionSignalKind.ready => 'ready for review',
      SessionSignalKind.stopped => 'disconnected',
    };
    final trimmed = message?.trim();
    final body = (trimmed != null && trimmed.isNotEmpty)
        ? '$base — $trimmed'
        : base;
    return SessionNotification(
      title: label,
      body: body,
      payload: sessionId,
      tag: '$_tagPrefix$sessionId',
    );
  }

  /// Parse the sessionId out of a notification payload. Tolerant of a null or
  /// empty payload (returns null → "no pending focus").
  static String? parsePayload(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    return payload;
  }
}

/// Minimal key/value persistence seam. Production binds this to the
/// foreground-task plugin's cross-isolate data store
/// (`FlutterForegroundTask.saveData/getData/removeData`), which survives
/// process death — so a tap on a cold-started app still routes to the right
/// session. Tests use [MapKeyValueStore].
abstract class KeyValueStore {
  Future<String?> getString(String key);
  Future<void> setString(String key, String value);
  Future<void> remove(String key);
}

/// In-memory [KeyValueStore] for tests.
class MapKeyValueStore implements KeyValueStore {
  final Map<String, String> _m = {};

  @override
  Future<String?> getString(String key) async => _m[key];

  @override
  Future<void> setString(String key, String value) async {
    _m[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    _m.remove(key);
  }
}

/// Cross-isolate "session to focus on next resume" hand-off (#575).
///
/// The notification tap is handled in the foreground-task isolate, which cannot
/// touch the UI's Riverpod containers. It records the originating sessionId
/// here (and calls `launchApp`); the UI isolate reads + clears it on resume.
class PendingFocusBridge {
  PendingFocusBridge(this._store);

  final KeyValueStore _store;

  /// Storage key. Namespaced to avoid clashing with other app data.
  static const String _key = 'mobissh.pendingFocusSessionId';

  /// Record [sessionId] as the session to focus when the UI next resumes.
  /// Latest write wins (the most recently tapped notification).
  Future<void> setPending(String sessionId) =>
      _store.setString(_key, sessionId);

  /// Non-destructive read of the pending focus, or null when none is pending.
  Future<String?> readPending() => _store.getString(_key);

  /// One-shot consume: returns the pending sessionId (or null) AND clears it so
  /// a later resume doesn't re-focus the same session.
  Future<String?> takePending() async {
    final v = await _store.getString(_key);
    if (v != null) await _store.remove(_key);
    return (v == null || v.isEmpty) ? null : v;
  }
}
