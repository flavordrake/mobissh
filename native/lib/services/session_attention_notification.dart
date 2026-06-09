// Attention NOTIFICATION layer (#840, Slice 2).
//
// Slice 1 shipped [AttentionSignalScanner], which detects in-band agent-attention
// signals (BEL / OSC 9 / OSC 777 / the notify-bell line) per session in the
// foreground-task isolate. Slice 2 turns a detection into a tappable Android
// notification whose tap returns the user to the EXACT originating session.
//
// This module owns the PURE, headless-testable pieces of that path so the
// platform-binding poster (`flutter_local_notifications`) and the cross-isolate
// hand-off stay thin:
//
//   1. [AttentionNotification] — maps a detected [AttentionSignal] (+ the
//      sessionId and an optional human session label) to the notification's
//      title/body, a per-session tag (so repeated signals from one session
//      REPLACE rather than stack — PWA notification-tag parity), and the opaque
//      JSON payload the tap carries back. The payload is exactly
//      `{sessionId, sourceWindow?}` plus a fixed human phrase — never auth
//      material (see the "no secret material" test).
//
//   2. [parseSourceWindow] — pulls a trailing `(win N)` source-window hint out of
//      the scanner's parsed text (the owner's tmux `alert-bell` hook appends it).
//      Defensive: absent / malformed → null.
//
//   3. [shouldPostAttention] — the suppression predicate. We do NOT post when the
//      signalling session is BOTH the active session AND the app is foregrounded
//      (the user is already looking at it).
//
//   4. [PendingFocusBridge] over a [KeyValueStore] — the cross-isolate hand-off.
//      The tap is delivered to the foreground-task isolate (or a background
//      callback); it records the originating sessionId in a store that survives
//      process death (production = FFT `saveData/getData`), and the UI isolate
//      reads + clears it on init (cold start) AND resume (warm) →
//      `sessionsProvider.notifier.setActive(sessionId)`.
//
// SECURITY: a notification only ever carries the opaque sessionId, an optional
// integer source-window, and a FIXED human phrase. It never carries a password,
// passphrase, key, host, or username — see `session_attention_notification_test`.

import 'dart:convert';

import 'attention_signal_scanner.dart';

/// Fixed, human-readable notification title. Intentionally generic + carries no
/// session-identifying material (the session is identified by the opaque tag /
/// payload, not the visible text).
const String kAttentionTitle = 'MobiSSH — Claude needs attention';

/// Tag prefix so an attention notification never collides with the
/// foreground-service keep-alive notification (channel `mobissh_keepalive`).
const String _tagPrefix = 'mobissh.attention.';

/// Android channel id for attention notifications — HIGH importance (loud,
/// dismissible), DISTINCT from the LOW `mobissh_keepalive` FGS channel.
const String kAttentionChannelId = 'mobissh_attention';
const String kAttentionChannelName = 'MobiSSH attention';
const String kAttentionChannelDescription =
    'Loud, dismissible alert when a remote session (e.g. Claude) asks for '
    'your attention.';

/// An immutable description of a tappable attention notification. Pure data —
/// the platform posting happens in [AttentionNotifier] implementations.
class AttentionNotification {
  const AttentionNotification({
    required this.title,
    required this.body,
    required this.tag,
    required this.payload,
    this.sourceWindow,
  });

  /// Notification title — the fixed [kAttentionTitle]. The session is NOT named
  /// in the title (no host/user leakage in the visible text).
  final String title;

  /// Notification body — the scanner's parsed text (the OSC-9 / OSC-777 /
  /// hook-line message), or a fixed fallback phrase when the signal had no text
  /// (a bare BEL). Stripped of any trailing `(win N)` hint, which is structured
  /// into [sourceWindow]/[payload] instead.
  final String body;

  /// Android notification tag. Keyed by sessionId so a later signal from the
  /// same session REPLACES the prior notification rather than stacking, while
  /// distinct sessions get distinct tags (PWA notification-tag parity).
  final String tag;

  /// Opaque JSON payload the tap carries: `{"sessionId": "...", "sourceWindow": N?}`.
  /// Routes the tap back to the originating session (and optionally its tmux
  /// source window). NEVER contains auth material.
  final String payload;

  /// Parsed tmux source-window number from a trailing `(win N)` hint, or null.
  final int? sourceWindow;

  /// Fixed fallback body for a text-less signal (a bare bell).
  static const String _fallbackBody = 'Session needs attention';

  /// Build a notification description for [sessionId] from a detected [signal].
  ///
  /// The body is the signal's parsed text with any trailing `(win N)` removed;
  /// the window number (when present) is structured into [sourceWindow] and the
  /// payload. A text-less signal (bare bell) uses [_fallbackBody].
  static AttentionNotification build({
    required String sessionId,
    required AttentionSignal signal,
  }) {
    final raw = signal.text?.trim();
    final win = parseSourceWindow(raw);
    final stripped = _stripSourceWindow(raw);
    final body = (stripped == null || stripped.isEmpty) ? _fallbackBody : stripped;
    final payloadMap = <String, dynamic>{'sessionId': sessionId};
    if (win != null) payloadMap['sourceWindow'] = win;
    return AttentionNotification(
      title: kAttentionTitle,
      body: body,
      tag: '$_tagPrefix$sessionId',
      payload: jsonEncode(payloadMap),
      sourceWindow: win,
    );
  }

  /// Parse a payload JSON string back into `(sessionId, sourceWindow?)`.
  /// Tolerant: a null/empty/malformed payload → `(null, null)` ("no focus").
  /// Also accepts a bare sessionId string (legacy / defensive).
  static ({String? sessionId, int? sourceWindow}) parsePayload(String? payload) {
    if (payload == null || payload.isEmpty) {
      return (sessionId: null, sourceWindow: null);
    }
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map) {
        final sid = decoded['sessionId'];
        final win = decoded['sourceWindow'];
        return (
          sessionId: (sid is String && sid.isNotEmpty) ? sid : null,
          sourceWindow: win is int ? win : null,
        );
      }
      // Not a map — treat the whole string as a bare sessionId.
      return (sessionId: payload, sourceWindow: null);
    } catch (_) {
      // Not JSON — treat as a bare sessionId (defensive against older payloads).
      return (sessionId: payload, sourceWindow: null);
    }
  }
}

/// Match a trailing `(win N)` hint, e.g. `Claude — main (win 3)`. The window
/// number is captured; surrounding whitespace tolerated.
final RegExp _winRe = RegExp(r'\(\s*win\s+(\d+)\s*\)\s*$', caseSensitive: false);

/// Pull the tmux source-window number out of a parsed signal [text]. Returns
/// null when there is no well-formed `(win N)` suffix (absent OR malformed —
/// e.g. `(win)`, `(win abc)`, `win 3` without parens). Defensive by design: the
/// guarded source-window navigation must SKIP silently on a miss.
int? parseSourceWindow(String? text) {
  if (text == null) return null;
  final m = _winRe.firstMatch(text);
  if (m == null) return null;
  return int.tryParse(m.group(1)!);
}

/// Remove a trailing `(win N)` hint (and the whitespace before it) from [text],
/// so the notification body reads cleanly. Returns null for null input.
String? _stripSourceWindow(String? text) {
  if (text == null) return null;
  return text.replaceFirst(_winRe, '').trimRight();
}

/// Suppression predicate (#840 Slice 2, step 3). Do NOT post when the signalling
/// session is BOTH the active session AND the app is foregrounded — the user is
/// already looking at it. Post in every other case (backgrounded, OR a non-active
/// session even while foregrounded).
///
/// [signalSessionId] — the session that produced the signal.
/// [activeSessionId] — the currently-active (front-most tab) session, or null.
/// [foreground] — whether the app/UI is foregrounded.
bool shouldPostAttention({
  required String signalSessionId,
  required String? activeSessionId,
  required bool foreground,
}) {
  final isActive = activeSessionId != null && activeSessionId == signalSessionId;
  return !(isActive && foreground);
}

/// Posts (and cancels) attention notifications. Abstracted so the task isolate
/// can bind it to `flutter_local_notifications` in production while unit + the
/// integration test inject a recording fake (no platform-channel binding).
abstract class AttentionNotifier {
  /// Post (or REPLACE, keyed by [AttentionNotification.tag]) the notification.
  Future<void> post(AttentionNotification n);

  /// Cancel a session's attention notification (e.g. once the user focuses it).
  Future<void> cancel(String sessionId);
}

/// In-memory [AttentionNotifier] for tests + the integration test seam. Records
/// every posted notification so a test can assert what would have shown.
class RecordingAttentionNotifier implements AttentionNotifier {
  final List<AttentionNotification> posted = <AttentionNotification>[];
  final List<String> cancelled = <String>[];

  @override
  Future<void> post(AttentionNotification n) async => posted.add(n);

  @override
  Future<void> cancel(String sessionId) async => cancelled.add(sessionId);
}

/// Minimal key/value persistence seam. Production binds this to the
/// foreground-task plugin's cross-isolate data store
/// (`FlutterForegroundTask.saveData/getData/removeData`), which survives process
/// death — so a tap on a cold-started app still routes to the right session.
/// Tests use [MapKeyValueStore].
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

/// Cross-isolate "session to focus on next resume/init" hand-off (#840 Slice 2).
///
/// The notification tap is handled outside the UI's Riverpod containers. It
/// records the originating sessionId (+ optional tmux source window) here; the
/// UI isolate reads + clears it on init (cold) and resume (warm) and calls
/// `sessionsProvider.notifier.setActive(sessionId)` (then optionally selects the
/// source window).
class PendingFocusBridge {
  PendingFocusBridge(this._store);

  final KeyValueStore _store;

  /// Storage key. Namespaced to avoid clashing with other app data.
  static const String _key = 'mobissh.attention.pendingFocus';

  /// Record a pending focus from a notification [payload]. Latest write wins.
  /// A payload that parses to no sessionId is a no-op (nothing to focus).
  Future<void> setPendingFromPayload(String? payload) async {
    final parsed = AttentionNotification.parsePayload(payload);
    if (parsed.sessionId == null) return;
    await _store.setString(_key, payload!);
  }

  /// Non-destructive read of the pending focus, or `(null, null)` when none.
  Future<({String? sessionId, int? sourceWindow})> readPending() async {
    final raw = await _store.getString(_key);
    return AttentionNotification.parsePayload(raw);
  }

  /// One-shot consume: returns the pending `(sessionId, sourceWindow?)` AND
  /// clears it so a later resume doesn't re-focus the same session.
  Future<({String? sessionId, int? sourceWindow})> takePending() async {
    final raw = await _store.getString(_key);
    if (raw != null) await _store.remove(_key);
    return AttentionNotification.parsePayload(raw);
  }
}
