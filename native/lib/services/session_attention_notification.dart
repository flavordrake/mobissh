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

/// (Re)connect REPLAY-suppression window (#851). A signal that arrives within
/// this cooldown AFTER a session reaches `connected` (initial connect AND every
/// reconnect / softDisconnected→connected) is treated as REPLAYED scrollback /
/// catch-up — tmux re-attach, shell re-init, or buffered history — NOT a live
/// "Claude needs you now" moment, so it does NOT post a notification (the owner:
/// "notifications shouldn't bubble up the second I reconnect"). After the window
/// settles, live signals post normally. The host re-arms this window on every
/// connected transition. Tunable; 1.5s is the owner's starting point.
const Duration kAttentionReplayWindow = Duration(milliseconds: 1500);

/// JUST-SWITCHED grace window (#856). When the user switches TO a session (the
/// app foregrounds it / it becomes the active host), the host flushes that
/// session's catch-up output; a bell in that burst would post a REDUNDANT
/// attention notification for the very session the user just switched to (the
/// owner: "I switched to fddev and immediately got a pop up that fddev needed my
/// attention — should not get that, it's redundant"). #847 host-suppression keys
/// on `activeHost`, but the catch-up output is scanned BEFORE the
/// `setActive(newHost)` command lands (async gateway race), and #851's replay
/// window only re-arms on a CONNECT transition — not on a session SWITCH (the
/// session was already connected). So when the active HOST changes, the host arms
/// this short grace for the newly-active host: a signal for that host within the
/// window is suppressed (logged) rather than posted. After the window, posts
/// normally. Composes with — does not replace — #847 + #851. Tunable; 1.5s
/// mirrors the replay window's catch-up-burst rationale.
const Duration kAttentionSwitchGraceWindow = Duration(milliseconds: 1500);

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
    this.url,
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

  /// Opaque JSON payload the tap carries:
  /// `{"sessionId": "...", "sourceWindow": N?, "url": "https://…"?}`.
  /// Routes the tap back to the originating session (and optionally its tmux
  /// source window), and — when the signal text carried one (#710) — the
  /// explicitly-signalled URL the tap should OPEN. NEVER contains auth material:
  /// the URL is extracted from the already-visible signal TEXT (e.g. a
  /// "Build ready: https://…" dev-loop signal), not from any credential field.
  final String payload;

  /// Parsed tmux source-window number from a trailing `(win N)` hint, or null.
  final int? sourceWindow;

  /// The first `http(s)://` URL carried in the signal text (#710), or null when
  /// the signal carried none. Only an EXPLICITLY-signalled URL becomes tappable
  /// (the "build ready → tap → install" case) — we never scan arbitrary terminal
  /// output. The URL also stays visible in [body]; the tap OPENS it (see
  /// [AttentionFocusRouter]).
  final String? url;

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
    // #710: extract an explicitly-signalled http(s) URL from the signal text so
    // the tap can OPEN it (the "Build ready: https://…" dev-loop case). Parsed
    // from the full raw text (not the win-stripped body) so a `(win N)` suffix
    // never interferes. The URL stays visible in the body — we only ADD a tap
    // action, we do not hide or rewrite the text.
    final url = parseUrl(raw);
    // #847: lead the body with the short host label so alerts are differentiated
    // BY SERVER (owner: "at minimum differentiate by server"). A bare bell (no
    // text) shows just the server; a signal with text shows "server — text".
    final label = hostLabelOfSessionId(sessionId);
    final body = (stripped == null || stripped.isEmpty)
        ? label
        : '$label — $stripped';
    final payloadMap = <String, dynamic>{'sessionId': sessionId};
    if (win != null) payloadMap['sourceWindow'] = win;
    // #710: carry the extracted URL so the tap handler can launch it. This is the
    // ONLY non-id field allowed in the payload, and it comes from the visible
    // signal text — never from credential material (see the no-secret test).
    if (url != null) payloadMap['url'] = url;
    return AttentionNotification(
      title: kAttentionTitle,
      body: body,
      // Per-HOST tag (#847): two sessions to the same host collapse to one
      // notification slot (replace, not stack). The tap payload still carries
      // the exact sessionId so focus routing is unchanged.
      tag: '$_tagPrefix${hostOfSessionId(sessionId)}',
      payload: jsonEncode(payloadMap),
      sourceWindow: win,
      url: url,
    );
  }

  /// Parse a payload JSON string back into `(sessionId, sourceWindow?, url?)`.
  /// Tolerant: a null/empty/malformed payload → `(null, null, null)` ("no
  /// focus"). Also accepts a bare sessionId string (legacy / defensive).
  static ({String? sessionId, int? sourceWindow, String? url}) parsePayload(
    String? payload,
  ) {
    if (payload == null || payload.isEmpty) {
      return (sessionId: null, sourceWindow: null, url: null);
    }
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map) {
        final sid = decoded['sessionId'];
        final win = decoded['sourceWindow'];
        final u = decoded['url'];
        return (
          sessionId: (sid is String && sid.isNotEmpty) ? sid : null,
          sourceWindow: win is int ? win : null,
          url: (u is String && u.isNotEmpty) ? u : null,
        );
      }
      // Not a map — treat the whole string as a bare sessionId.
      return (sessionId: payload, sourceWindow: null, url: null);
    } catch (_) {
      // Not JSON — treat as a bare sessionId (defensive against older payloads).
      return (sessionId: payload, sourceWindow: null, url: null);
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

/// Match an absolute `http://` / `https://` URL in the signal text (#710). A
/// focused, http(s)-ONLY matcher (no bare `www.`, no other schemes) — the
/// notification only makes an EXPLICITLY-signalled web URL tappable (the
/// "Build ready: https://…" dev-loop case). The character class stops at
/// whitespace and the few characters terminals/shells never put mid-URL; a
/// separate trailing trim removes sentence punctuation / unbalanced closers.
final RegExp _urlRe = RegExp(
  r'''https?://[^\s<>"'`]+''',
  caseSensitive: false,
);

/// Trailing characters trimmed off the END of a raw URL match (#710). Mirrors
/// the in-fork `structured_text` URL detector so `https://x.com/p).` →
/// `https://x.com/p`.
const String _urlTrailingTrim = '.,;:!?)]}>\'"';

/// Extract the FIRST `http(s)://` URL from [text] (#710), trimmed of trailing
/// sentence punctuation / unbalanced closers. Returns null when [text] is null,
/// empty, or carries no http(s) URL (bare `www.` and non-http schemes do NOT
/// match — only an explicitly web-addressable URL becomes tappable). The URL is
/// taken from the visible signal text and is never auth material.
String? parseUrl(String? text) {
  if (text == null || text.isEmpty) return null;
  final m = _urlRe.firstMatch(text);
  if (m == null) return null;
  var url = m.group(0)!;
  while (url.isNotEmpty && _urlTrailingTrim.contains(url[url.length - 1])) {
    url = url.substring(0, url.length - 1);
  }
  return url.isEmpty ? null : url;
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

/// Internal JSON key used to stamp a pending-focus write with a monotonic
/// sequence number (#870). It is an UNDERSCORE-prefixed, payload-internal field
/// — `AttentionNotification.parsePayload` already ignores unknown keys, so a
/// stamped payload round-trips through every existing reader unchanged (the
/// stamp is never surfaced to the router and never reaches a notification). The
/// stamp lets `takePending` resolve the write↔read race (#870): a fresh tap's
/// write carries a HIGHER seq than a stale, never-consumed prior entry, so the
/// consume can prefer the freshest write.
const String _kPendingSeqKey = '_seq';

/// Process-wide monotonic sequence source for pending-focus writes (#870).
/// Each [PendingFocusBridge.setPendingFromPayload] stamps the next value. It is
/// seeded from the wall clock (so writes from DIFFERENT isolates — the FGS task
/// isolate's foreground tap vs. the background-tap isolate — order roughly by
/// real time) but strictly increasing within an isolate (ties broken by an
/// incrementing counter), so two writes in the same millisecond still order.
int _lastPendingSeq = 0;
int _nextPendingSeq() {
  final now = DateTime.now().millisecondsSinceEpoch;
  final next = now > _lastPendingSeq ? now : _lastPendingSeq + 1;
  _lastPendingSeq = next;
  return next;
}

/// Extract the `_seq` stamp from a stored pending payload, or null when absent
/// (an unstamped legacy write, or a non-JSON payload). Defensive: never throws.
int? _seqOf(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      final s = decoded[_kPendingSeqKey];
      if (s is int) return s;
    }
  } catch (_) {
    // Not JSON / malformed — treat as unstamped.
  }
  return null;
}

/// Cross-isolate "session to focus on next resume/init" hand-off (#840 Slice 2).
///
/// The notification tap is handled outside the UI's Riverpod containers. It
/// records the originating sessionId (+ optional tmux source window) here; the
/// UI isolate reads + clears it on init (cold) and resume (warm) and calls
/// `sessionsProvider.notifier.setActive(sessionId)` (then optionally selects the
/// source window).
///
/// #870 race hardening: a foreground tap WRITES the pending entry asynchronously
/// (cross-isolate, to disk) while the SAME tap also foregrounds the app →
/// `resumed` → `takePending` READS. If the read beats the write it consumes a
/// STALE, never-consumed prior entry (e.g. an earlier nv-dev tap) and routes to
/// the wrong host. `takePending` mitigates this by stamping each write with a
/// monotonic seq and, on consume, yielding once to let an in-flight fresher
/// write land — preferring the higher-seq entry so the JUST-TAPPED write wins.
class PendingFocusBridge {
  PendingFocusBridge(
    this._store, {
    this.log,
    this.raceGrace = const Duration(milliseconds: 16),
  });

  final KeyValueStore _store;

  /// Telemetry seam (#870). Production binds this to `ctrace` so the pending
  /// WRITE lands in the uploaded connect-log ring; null in unit tests that don't
  /// assert logging. Logs sid/host only — never auth material.
  final void Function(String where, String msg)? log;

  /// How long [takePending] yields to let an in-flight cross-isolate write land
  /// before committing to a consume (#870). Injectable so a unit test can drive
  /// the race deterministically (a write scheduled inside the grace must win).
  final Duration raceGrace;

  /// Storage key. Namespaced to avoid clashing with other app data.
  static const String _key = 'mobissh.attention.pendingFocus';

  /// Record a pending focus from a notification [payload]. Latest write wins.
  /// A payload that parses to no sessionId is a no-op (nothing to focus). The
  /// stored value is stamped with a monotonic `_seq` (#870) so a later consume
  /// can resolve the write↔read race in favour of the freshest write.
  Future<void> setPendingFromPayload(String? payload) async {
    final parsed = AttentionNotification.parsePayload(payload);
    final sid = parsed.sessionId;
    if (sid == null) return;
    final stamped = _stampSeq(payload!);
    await _store.setString(_key, stamped);
    // #870: log the WRITE so the write/read ORDER is visible in a capture (the
    // next device report can show whether the consume raced ahead of this).
    log?.call(
      'ui.attention',
      'pending set sid=$sid host=${hostOfSessionId(sid)}',
    );
  }

  /// Re-encode [payload] with a fresh monotonic `_seq` stamp (#870). Falls back
  /// to the raw payload if it isn't a JSON object (a bare-id legacy payload — it
  /// still round-trips through `parsePayload`, just without a stamp).
  String _stampSeq(String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map) {
        final m = Map<String, dynamic>.from(decoded);
        m[_kPendingSeqKey] = _nextPendingSeq();
        return jsonEncode(m);
      }
    } catch (_) {
      // Non-JSON payload — store verbatim (unstamped).
    }
    return payload;
  }

  /// Non-destructive read of the pending focus, or `(null, null, null)` when
  /// none.
  Future<({String? sessionId, int? sourceWindow, String? url})>
      readPending() async {
    final raw = await _store.getString(_key);
    return AttentionNotification.parsePayload(raw);
  }

  /// One-shot consume: returns the pending `(sessionId, sourceWindow?, url?)`
  /// AND clears it so a later resume doesn't re-focus the same session.
  ///
  /// #870: resolves the write↔read race. After the initial read it yields once
  /// (the [_raceGrace] window) and re-reads; if a FRESHER write landed in the
  /// meantime (a higher `_seq`, e.g. the just-tapped notification's pending
  /// arriving from another isolate) that fresher entry is consumed instead of
  /// the stale one. The entry is removed on consume so a never-re-consumed stale
  /// tap can't be served later.
  Future<({String? sessionId, int? sourceWindow, String? url})>
      takePending() async {
    final first = await _store.getString(_key);
    // Yield once so an in-flight cross-isolate write (the just-tapped pending)
    // can land before we commit to consuming. A single short yield is enough to
    // let the FFT disk write flush + the store reflect it; it does NOT block the
    // resume path meaningfully (sub-frame). We yield even when the first read
    // was empty: the racing write may not have landed yet at all.
    await Future<void>.delayed(raceGrace);
    final second = await _store.getString(_key);

    // Pick the FRESHER of the two reads by seq. If the second read produced a
    // higher-seq entry (a newer write raced in), prefer it; otherwise keep the
    // first. Unstamped (legacy) entries sort below any stamped one.
    final firstSeq = _seqOf(first) ?? -1;
    final secondSeq = _seqOf(second) ?? -1;
    final chosen = (second != null && secondSeq > firstSeq) ? second : first;

    // #875: log the race RESOLUTION UI-side (this runs in the UI isolate, so it
    // lands in the UPLOADED connect ring — unlike the WRITE log, which fires in
    // the throwaway tap isolate and is never captured). Shows whether the grace
    // let a fresher write land (`raced-in`) or the consume committed to the
    // first read (`first` — the wrong-host suspect when the cross-isolate write
    // hadn't flushed within the grace). Sids/seqs only; never auth material.
    String sidShort(String? raw) {
      final sid = AttentionNotification.parsePayload(raw).sessionId;
      return sid == null ? 'none' : hostOfSessionId(sid);
    }

    final racedIn = second != null && secondSeq > firstSeq;
    log?.call(
      'ui.attention',
      'takePending: first=${sidShort(first)}/$firstSeq '
      'second=${sidShort(second)}/$secondSeq '
      '→ ${sidShort(chosen)} (${racedIn ? 'raced-in' : 'first'})',
    );

    if (chosen == null) {
      return AttentionNotification.parsePayload(null);
    }

    // Clear the entry so a later resume doesn't re-focus the same session and a
    // never-consumed stale tap can't be served later (#870).
    await _store.remove(_key);
    return AttentionNotification.parsePayload(chosen);
  }
}
