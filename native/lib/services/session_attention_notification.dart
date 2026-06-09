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
/// Keyed by HOST (#847), not session: the unit of attention is the host (the
/// Claude), so two sessions to the same host share one tag → a repeat REPLACES
/// rather than stacks (the #847 "two stacked identical alerts" bug).
const String _tagPrefix = 'mobissh.attention.';

/// Cross-session attention dedup window (#847). Multiple bells from multiple
/// sessions to the SAME host within this window collapse to ONE notification —
/// a single underlying Claude event reaching two PTYs should not double-alert.
/// Tunable; 30s is the owner's starting point.
const Duration kAttentionDedupWindow = Duration(seconds: 30);

/// Derive the HOST from a sessionId (#847). The session id format is
/// `host:port:user:createdAtMs` (see `state/sessions.dart`), so the host is the
/// segment before the first colon. Falls back to the whole id when it has no
/// colon (defensive — e.g. a synthetic test id), so dedup/suppression still
/// keys on a stable value. Never returns null.
String hostOfSessionId(String sessionId) {
  final i = sessionId.indexOf(':');
  if (i <= 0) return sessionId;
  return sessionId.substring(0, i);
}

/// Short, human display label for the host of [sessionId] — the first
/// dot-segment of the host (e.g. `fd-dev` from `fd-dev.tailbe5094.ts.net`), so
/// an attention notification is differentiated BY SERVER (#847 owner request:
/// "at minimum differentiate by server") without the long tailnet FQDN. These
/// are the owner's own machines on a private tailnet — the short host name is
/// not sensitive and is what the owner uses to tell sessions apart. Falls back
/// to the full host when there is no dot.
String hostLabelOfSessionId(String sessionId) {
  final host = hostOfSessionId(sessionId);
  final dot = host.indexOf('.');
  return dot <= 0 ? host : host.substring(0, dot);
}

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

  /// Notification body — leads with the short host label (#847: differentiate by
  /// server) followed by the scanner's parsed text (the OSC-9 / OSC-777 /
  /// hook-line message): `"server — text"`. A text-less signal (a bare BEL) is
  /// just `"server"`. Stripped of any trailing `(win N)` hint, which is
  /// structured into [sourceWindow]/[payload] instead.
  final String body;

  /// Android notification tag. Keyed by HOST (#847) so a later signal from the
  /// same host — including a DIFFERENT session to that host — REPLACES the prior
  /// notification rather than stacking (the #847 "two stacked identical alerts"
  /// bug), while distinct hosts get distinct tags. The payload still routes the
  /// tap to the exact originating session.
  final String tag;

  /// Opaque JSON payload the tap carries: `{"sessionId": "...", "sourceWindow": N?}`.
  /// Routes the tap back to the originating session (and optionally its tmux
  /// source window). NEVER contains auth material.
  final String payload;

  /// Parsed tmux source-window number from a trailing `(win N)` hint, or null.
  final int? sourceWindow;

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
    // #847: lead the body with the short host label so alerts are differentiated
    // BY SERVER (owner: "at minimum differentiate by server"). A bare bell (no
    // text) shows just the server; a signal with text shows "server — text".
    final label = hostLabelOfSessionId(sessionId);
    final body = (stripped == null || stripped.isEmpty)
        ? label
        : '$label — $stripped';
    final payloadMap = <String, dynamic>{'sessionId': sessionId};
    if (win != null) payloadMap['sourceWindow'] = win;
    return AttentionNotification(
      title: kAttentionTitle,
      body: body,
      // Per-HOST tag (#847): two sessions to the same host collapse to one
      // notification slot (replace, not stack). The tap payload still carries
      // the exact sessionId so focus routing is unchanged.
      tag: '$_tagPrefix${hostOfSessionId(sessionId)}',
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

/// Host-level suppression predicate (#847; supersedes the #840 session-level
/// rule). The unit of attention is the HOST (the Claude), not the individual
/// session. Do NOT post when the app is FOREGROUNDED and the front-most session's
/// HOST equals the signalling session's HOST — the user is already looking at
/// that Claude, even via a DIFFERENT session to the same host. Post in every
/// other case: backgrounded, OR foregrounded on a session to a DIFFERENT host.
///
/// [signalSessionId] — the session that produced the signal.
/// [activeSessionId] — the currently-active (front-most tab) session, or null.
/// [activeHost] — the HOST of the front-most session, or null when unknown.
/// [foreground] — whether the app/UI is foregrounded.
bool shouldPostAttention({
  required String signalSessionId,
  required String? activeSessionId,
  String? activeHost,
  required bool foreground,
}) {
  if (!foreground) return true;
  final signalHost = hostOfSessionId(signalSessionId);
  // Prefer the explicit activeHost (the host of the front-most session as
  // reported by the UI). Fall back to deriving it from activeSessionId so an
  // older UI (or a path that only knows the id) still host-suppresses correctly.
  final frontHost = (activeHost != null && activeHost.isNotEmpty)
      ? activeHost
      : (activeSessionId != null ? hostOfSessionId(activeSessionId) : null);
  if (frontHost == null) return true;
  // Suppress when foregrounded on the SAME host (any session to that host).
  return frontHost != signalHost;
}

/// Host-level cross-session dedup (#847). Multiple bells from multiple sessions
/// to the SAME host within [window] collapse to ONE notification: a single
/// Claude event reaching two PTYs must not double-alert. Pure + clock-injected
/// so it is deterministically unit-testable; the host owns one instance and
/// consults it right before posting.
class AttentionDedupTracker {
  AttentionDedupTracker({
    this.window = kAttentionDedupWindow,
    int Function()? nowMs,
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// Dedup window. A post for a host within [window] of its last ALLOWED post is
  /// suppressed.
  final Duration window;
  final int Function() _nowMs;

  /// Last ALLOWED post time per host (ms since epoch).
  final Map<String, int> _lastPostMs = {};

  /// Record a post for [host] and return whether it should actually fire. The
  /// FIRST post for a host (or the first after the window elapses) returns true
  /// and stamps the time; a repeat within [window] returns false WITHOUT moving
  /// the stamp (so the window measures from the last fired post, not the last
  /// attempt). Keyed by host so two sessions to the same host dedup together.
  bool allow(String host) {
    final now = _nowMs();
    final last = _lastPostMs[host];
    if (last != null && (now - last) < window.inMilliseconds) {
      return false;
    }
    _lastPostMs[host] = now;
    return true;
  }

  /// Forget a host's last-post stamp (e.g. on shell re-open / reset).
  void reset() => _lastPostMs.clear();
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
