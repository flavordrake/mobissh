// In-app byte + scroll-event recorder (#790) — replay-harness TRACE PRODUCER.
//
// The Feedback FRAME recorder captures rendered OUTPUT (pixels, forward ~10s).
// It can't REPRODUCE a scrollback-render bug (#789 scroll-stuck, #772 cursor
// block, #773 delayed paint, outline-drift) because it never captured the INPUT
// — the raw byte stream flterm/Terminal received — or the scroll gestures that
// produced the buggy frame. This module records both, per active session, into
// a continuously-running, bounded, BACKWARD-looking ring, so a captured trace
// can later be replayed (#791, the SEPARATE follow-up slice) into a real
// Terminal widget headlessly and the bug reproduced + fixed at the source.
//
// Design (mirrors connect_trace.dart / gesture_trace.dart):
//   - One [SessionByteRecorder] per live session, kept in a global registry
//     keyed by sessionId, with a single "active" pointer the feedback overlay
//     reads at Feedback time (`activeByteTraceSnapshot()` etc.).
//   - The byte ring stores the raw [Uint8List] reference + a relative-ms
//     timestamp — ALLOCATION-LIGHT on the hot path (this records the very scroll
//     path #789 suspects of jank; no per-event copy, no per-event base64). The
//     b64 encoding + secret scrub happen ONCE at SNAPSHOT time (cold path).
//   - Bounded by total bytes (~256 KB) AND age (~30 s), whichever evicts first —
//     it's backward-looking so the bytes that produced the current buggy state
//     are present when the user hits Feedback.
//   - The scroll ring stores `{tMs, offset}` bounded by event count + age. Grid
//     `{cols, rows}` tracks the latest viewport (updated on resize).
//
// SECURITY (rules/security.md / #553 contract): the byte stream is terminal
// OUTPUT and MAY contain secrets (an echoed token, a sudo prompt echo). The
// snapshot decodes each chunk, runs it through [scrubSecrets] (shared with the
// feedback bundle), and re-encodes — so credential-looking lines NEVER leave the
// device. Scrubbing at snapshot (cold path) keeps the hot path allocation-light.

import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'feedback_bundle.dart' show scrubSecrets;

/// Default byte-ring cap: ~1 MB of the most recent terminal output. Past this
/// the oldest chunks are evicted (backward-looking — newest always wins).
///
/// #1072: raised from 256 KB → 1 MB so a RESUME-SPANNING window survives. The
/// DA-leak repro straddles suspend/resume; on a busy terminal 256 KB held only
/// a few seconds, evicting the pre-resume bytes before the report was captured.
/// 1 MB (with the 60 s age cap below) holds the full ~30 s+ window the byte
/// stream needs to show what happened across the resume. Conservative: 4× the
/// old cap, still bounded and backward-looking.
const int kByteRecorderMaxBytes = 1024 * 1024;

/// Default byte-ring event cap (defense against a flood of tiny chunks blowing
/// the list length even under the byte cap). #1072: raised in step with the
/// 4× byte cap so the event cap is not the new binding limit.
const int kByteRecorderMaxEvents = 16384;

/// Default age cap for the byte/scroll/termReply rings: ~60 s. Events older than
/// this (relative to the newest event) are evicted. #1072: raised from 30 s →
/// 60 s so a suspend/resume-spanning window is retained (the byte cap above is
/// still the usual binding limit on a busy terminal).
const Duration kByteRecorderMaxAge = Duration(seconds: 60);

/// Default scroll-ring event cap.
const int kScrollRecorderMaxEvents = 2048;

/// Default sent-SGR-ring event cap (#793). The synthesized mouse/wheel reports
/// the app SENDS are short and infrequent; a modest cap holds a full swipe burst.
const int kSentSgrRecorderMaxEvents = 1024;

/// #1072: default terminal-auto-reply ring event cap. DA/DSR/CPR/XTVERSION/OSC
/// replies are short and infrequent; a modest cap holds a full burst. Age
/// eviction shares [kByteRecorderMaxAge].
const int kTermReplyRecorderMaxEvents = 1024;

class _ByteEvent {
  _ByteEvent(this.tMs, this.bytes);
  final int tMs;
  final Uint8List bytes;
}

class _ScrollEvent {
  _ScrollEvent(this.tMs, this.offset);
  final int tMs;
  final int offset;
}

/// #793: true iff [chunk] is a synthesized SGR-1006 mouse/wheel report — the
/// ONLY bytes the sent ring is allowed to capture. An SGR-1006 mouse report is
/// `ESC [ < ... M` (press/motion) or `ESC [ < ... m` (release): byte sequence
/// `0x1b 0x5b 0x3c` (`ESC[<`) terminated by `M` (0x4d) or `m` (0x6d). A typed
/// keystroke, password, control char, or Enter is NOT this shape, so it can
/// never enter the ring — typed secrets are never recorded (rules/security.md).
/// Pure + allocation-free (byte scan, no decode).
bool isSentSgrMouseReport(Uint8List chunk) {
  // Need at least `ESC[<` + terminator.
  if (chunk.length < 4) return false;
  if (chunk[0] != 0x1b || chunk[1] != 0x5b || chunk[2] != 0x3c) return false;
  final last = chunk[chunk.length - 1];
  if (last != 0x4d && last != 0x6d) return false; // not M / m terminated
  // Between the prefix and the terminator only digits and ';' are valid in an
  // SGR-1006 mouse report — reject anything else so a crafted-looking prefix
  // that actually carries other bytes (and could embed typed content) is dropped.
  for (var i = 3; i < chunk.length - 1; i++) {
    final b = chunk[i];
    final isDigit = b >= 0x30 && b <= 0x39;
    final isSemi = b == 0x3b;
    if (!isDigit && !isSemi) return false;
  }
  return true;
}

/// #1072: coarse classification of a terminal AUTO-REPLY chunk by its leading
/// bytes, for the term-reply diagnostics trace. Pure + allocation-free.
///
///   `DA1`      `ESC [ ?` (`\x1b[?…`)  — primary device attributes reply
///   `DA2`      `ESC [ >` (`\x1b[>…`)  — secondary device attributes reply
///   `DSR`/`CPR``ESC [` + digits + `R`/`n` — cursor position / device status
///   `OSC`      `ESC ]`               — OSC query answer
///   `other`    anything else (e.g. XTVERSION `ESC P … ST`)
///
/// Best-effort: it only inspects the shape, never decodes content, so it can't
/// leak anything a scrub would catch.
String termReplyKind(Uint8List chunk) {
  if (chunk.length < 2) return 'other';
  if (chunk[0] != 0x1b) return 'other';
  // OSC: ESC ]
  if (chunk[1] == 0x5d) return 'OSC';
  // CSI replies: ESC [
  if (chunk[1] == 0x5b) {
    if (chunk.length >= 3) {
      if (chunk[2] == 0x3f) return 'DA1'; // ESC [ ?
      if (chunk[2] == 0x3e) return 'DA2'; // ESC [ >
    }
    // DSR/CPR: ESC [ <digits/;> terminated by 'R' (0x52) or 'n' (0x6e).
    final last = chunk[chunk.length - 1];
    if (last == 0x52 || last == 0x6e) return chunk[chunk.length - 1] == 0x52 ? 'CPR' : 'DSR';
    return 'other';
  }
  return 'other';
}

/// A bounded, backward-looking recorder of the raw bytes written to ONE
/// session's terminal plus its scroll-offset events. See the file header.
class SessionByteRecorder {
  SessionByteRecorder({
    this.maxBytes = kByteRecorderMaxBytes,
    this.maxEvents = kByteRecorderMaxEvents,
    this.maxAge = kByteRecorderMaxAge,
    this.maxScrollEvents = kScrollRecorderMaxEvents,
    this.maxSentSgrEvents = kSentSgrRecorderMaxEvents,
    this.maxTermReplyEvents = kTermReplyRecorderMaxEvents,
    int Function()? nowMs,
  }) : _nowMs = nowMs ?? _defaultNowMs;

  final int maxBytes;
  final int maxEvents;
  final Duration maxAge;
  final int maxScrollEvents;
  final int maxSentSgrEvents;
  final int maxTermReplyEvents;

  /// Monotonic relative-ms clock. Injected in tests for determinism; production
  /// uses an epoch-anchored elapsed millis.
  final int Function() _nowMs;

  // Ring buffers. ListQueue (#793) used as FIFO queues — eviction is from the
  // FRONT (oldest) via O(1) `removeFirst`, NOT List.removeAt(0) (O(n) shift on
  // the hot path). Allocation-light: no per-event wrapper churn beyond the small
  // _ByteEvent/_ScrollEvent holders, and crucially NO byte copy/encode on the
  // hot path.
  final ListQueue<_ByteEvent> _bytes = ListQueue<_ByteEvent>();
  int _byteTotal = 0;
  final ListQueue<_ScrollEvent> _scroll = ListQueue<_ScrollEvent>();
  // #793: sent-SGR ring — ONLY the synthesized mouse/wheel SGR reports the app
  // WRITES to the proxy (filtered by [isSentSgrMouseReport]). Reveals "swipe →
  // wheel events emitted → tmux scrolled" in tmux mouse mode (where the local
  // scroll never moves). NEVER carries keystrokes, so a typed password can never
  // be recorded — the filter is the security boundary.
  final ListQueue<_ByteEvent> _sentSgr = ListQueue<_ByteEvent>();
  // #1072: terminal auto-reply ring — the DA/DSR/CPR/XTVERSION/OSC responses the
  // terminal itself writes back (teed from flterm's `onWritePty`, never user
  // keystrokes). Reveals a spurious/duplicated device-attributes reply (the
  // #1072 DA-leak). Each event also carries a coarse `kind` computed at snapshot.
  final ListQueue<_ByteEvent> _termReply = ListQueue<_ByteEvent>();

  int? _cols;
  int? _rows;

  static final int _epoch = DateTime.now().millisecondsSinceEpoch;
  static int _defaultNowMs() =>
      DateTime.now().millisecondsSinceEpoch - _epoch;

  /// Append a chunk of raw terminal-output [chunk]. Hot path: stores the
  /// reference + a timestamp, then evicts past the byte/event/age caps. No
  /// copy, no encode here.
  void recordBytes(Uint8List chunk) {
    if (chunk.isEmpty) return;
    final t = _nowMs();
    _bytes.add(_ByteEvent(t, chunk));
    _byteTotal += chunk.length;
    _evictBytes(t);
  }

  void _evictBytes(int nowMs) {
    final ageFloor = nowMs - maxAge.inMilliseconds;
    // Age + byte-cap + event-cap eviction, oldest-first.
    while (_bytes.isNotEmpty &&
        (_bytes.first.tMs < ageFloor ||
            _byteTotal > maxBytes ||
            _bytes.length > maxEvents)) {
      // Never evict the only (newest) chunk on the byte cap — a single chunk
      // larger than the cap must still be retained so the newest output is
      // present. Age eviction may still drop it once it's stale.
      if (_bytes.length == 1 && _bytes.first.tMs >= ageFloor) break;
      _byteTotal -= _bytes.first.bytes.length;
      _bytes.removeFirst();
    }
  }

  /// #793: append a chunk of bytes the app WROTE to the proxy, but ONLY if it is
  /// a synthesized SGR-1006 mouse/wheel report ([isSentSgrMouseReport]). Any
  /// other chunk (a typed keystroke, password, control char, Enter) is dropped
  /// here — it never enters the ring, so typed secrets are never recorded
  /// (rules/security.md). Hot path: a cheap byte-scan filter, then store the
  /// reference + timestamp. No copy/encode here (cold path at snapshot).
  void recordSentSgr(Uint8List chunk) {
    if (!isSentSgrMouseReport(chunk)) return;
    final t = _nowMs();
    _sentSgr.add(_ByteEvent(t, chunk));
    final ageFloor = t - maxAge.inMilliseconds;
    while (_sentSgr.isNotEmpty &&
        (_sentSgr.first.tMs < ageFloor ||
            _sentSgr.length > maxSentSgrEvents)) {
      if (_sentSgr.length == 1 && _sentSgr.first.tMs >= ageFloor) break;
      _sentSgr.removeFirst();
    }
  }

  /// #1072: append a terminal AUTO-REPLY chunk (teed from flterm's
  /// `onWritePty`). These are the terminal's own DA/DSR/CPR/XTVERSION/OSC
  /// responses — NOT user keystrokes, which never reach `onWritePty` — so a
  /// typed password can't enter this ring. Hot path: store the reference +
  /// timestamp, then evict past the age/event caps. No copy/encode here (cold
  /// path at snapshot). Same eviction discipline as the sent-SGR ring.
  void recordTermReply(Uint8List chunk) {
    if (chunk.isEmpty) return;
    final t = _nowMs();
    _termReply.add(_ByteEvent(t, chunk));
    final ageFloor = t - maxAge.inMilliseconds;
    while (_termReply.isNotEmpty &&
        (_termReply.first.tMs < ageFloor ||
            _termReply.length > maxTermReplyEvents)) {
      if (_termReply.length == 1 && _termReply.first.tMs >= ageFloor) break;
      _termReply.removeFirst();
    }
  }

  /// Append a scroll-offset event. Hot path on every scroll change.
  void recordScroll(int offset) {
    final t = _nowMs();
    _scroll.add(_ScrollEvent(t, offset));
    final ageFloor = t - maxAge.inMilliseconds;
    while (_scroll.isNotEmpty &&
        (_scroll.first.tMs < ageFloor || _scroll.length > maxScrollEvents)) {
      if (_scroll.length == 1 && _scroll.first.tMs >= ageFloor) break;
      _scroll.removeFirst();
    }
  }

  /// Record the latest viewport grid (cols × rows). Cheap; called on resize.
  void recordGrid(int cols, int rows) {
    _cols = cols;
    _rows = rows;
  }

  /// Snapshot the byte ring as a list of `{tMs, b64}`, oldest first. SCRUBS each
  /// chunk's UTF-8 projection of credential material before re-encoding, so no
  /// secret leaves the device (rules/security.md). Cold path — encode + scrub
  /// happen here, not on the hot path.
  List<Map<String, Object?>> snapshotByteTrace() {
    final out = <Map<String, Object?>>[];
    for (final ev in _bytes) {
      // Decode lossily, scrub, re-encode. A scrub that changes nothing is the
      // common case; the round-trip preserves valid UTF-8 exactly.
      final text = utf8.decode(ev.bytes, allowMalformed: true);
      final scrubbed = scrubSecrets(text);
      final bytes = identical(scrubbed, text) || scrubbed == text
          ? ev.bytes
          : Uint8List.fromList(utf8.encode(scrubbed));
      out.add(<String, Object?>{'tMs': ev.tMs, 'b64': base64Encode(bytes)});
    }
    return out;
  }

  /// #793: snapshot the sent-SGR ring as a list of `{tMs, b64}`, oldest first.
  /// Scrubs each chunk (defense in depth — mouse reports carry no credentials,
  /// but the ring uses the same cold-path scrub as the output ring). Encode +
  /// scrub happen here, not on the hot path.
  List<Map<String, Object?>> snapshotSentSgrTrace() {
    final out = <Map<String, Object?>>[];
    for (final ev in _sentSgr) {
      final text = utf8.decode(ev.bytes, allowMalformed: true);
      final scrubbed = scrubSecrets(text);
      final bytes = identical(scrubbed, text) || scrubbed == text
          ? ev.bytes
          : Uint8List.fromList(utf8.encode(scrubbed));
      out.add(<String, Object?>{'tMs': ev.tMs, 'b64': base64Encode(bytes)});
    }
    return out;
  }

  /// #1072: snapshot the terminal-auto-reply ring as a list of
  /// `{tMs, b64, kind}`, oldest first. SCRUBS each chunk (defense in depth —
  /// device-attributes/cursor replies carry no credentials, but the ring uses
  /// the same cold-path scrub as the output ring) and tags a coarse [kind].
  /// Encode + scrub + classify happen here, not on the hot path.
  List<Map<String, Object?>> snapshotTermReplyTrace() {
    final out = <Map<String, Object?>>[];
    for (final ev in _termReply) {
      final text = utf8.decode(ev.bytes, allowMalformed: true);
      final scrubbed = scrubSecrets(text);
      final bytes = identical(scrubbed, text) || scrubbed == text
          ? ev.bytes
          : Uint8List.fromList(utf8.encode(scrubbed));
      out.add(<String, Object?>{
        'tMs': ev.tMs,
        'b64': base64Encode(bytes),
        'kind': termReplyKind(ev.bytes),
      });
    }
    return out;
  }

  /// #793 (test-only): the live total of bytes retained in the byte ring, so the
  /// O(1)-eviction tests can assert `_byteTotal` stays consistent with the
  /// surviving chunks after `ListQueue` eviction.
  int get debugByteTotal => _byteTotal;

  /// Snapshot the scroll ring as a list of `{tMs, offset}`, oldest first.
  List<Map<String, Object?>> snapshotScrollTrace() {
    return _scroll
        .map((e) => <String, Object?>{'tMs': e.tMs, 'offset': e.offset})
        .toList(growable: false);
  }

  /// The latest viewport grid `{cols, rows}`, or null if never recorded.
  Map<String, Object?>? grid() {
    if (_cols == null || _rows == null) return null;
    return <String, Object?>{'cols': _cols, 'rows': _rows};
  }

  /// Drop all buffered events (e.g. on session teardown).
  void clear() {
    _bytes.clear();
    _byteTotal = 0;
    _scroll.clear();
    _sentSgr.clear();
    _termReply.clear();
    _cols = null;
    _rows = null;
  }
}

// ---------------------------------------------------------------------------
// Global registry + active pointer. Mirrors the connect/gesture trace pattern:
// the feedback overlay reads `activeByteTraceSnapshot()` etc. for whichever
// session is currently on screen, without a Riverpod dependency in its
// above-the-Navigator context.
// ---------------------------------------------------------------------------

final Map<String, SessionByteRecorder> _recorders =
    <String, SessionByteRecorder>{};
String? _activeSessionId;

/// Register (or fetch) the recorder for [sessionId]. Idempotent: returns the
/// existing recorder if one is already registered for that id.
SessionByteRecorder registerByteRecorder(String sessionId) {
  return _recorders.putIfAbsent(sessionId, SessionByteRecorder.new);
}

/// The recorder for [sessionId], or null if none is registered.
SessionByteRecorder? byteRecorderFor(String sessionId) => _recorders[sessionId];

/// Drop the recorder for [sessionId] (session teardown). Clears the active
/// pointer if it referenced this session.
void unregisterByteRecorder(String sessionId) {
  _recorders.remove(sessionId)?.clear();
  if (_activeSessionId == sessionId) _activeSessionId = null;
}

/// Mark [sessionId] as the active (on-screen) session whose rings the feedback
/// overlay snapshots. Pass null when no terminal is foregrounded.
void setActiveByteRecorder(String? sessionId) {
  _activeSessionId = sessionId;
}

SessionByteRecorder? get _active {
  final id = _activeSessionId;
  if (id == null) return null;
  return _recorders[id];
}

/// Byte trace of the active session, or empty when none is active.
List<Map<String, Object?>> activeByteTraceSnapshot() =>
    _active?.snapshotByteTrace() ?? const <Map<String, Object?>>[];

/// Scroll trace of the active session, or empty when none is active.
List<Map<String, Object?>> activeScrollTraceSnapshot() =>
    _active?.snapshotScrollTrace() ?? const <Map<String, Object?>>[];

/// #793: sent-SGR trace (synthesized mouse/wheel reports the app sent) of the
/// active session, or empty when none is active.
List<Map<String, Object?>> activeSentSgrTraceSnapshot() =>
    _active?.snapshotSentSgrTrace() ?? const <Map<String, Object?>>[];

/// #1072: terminal auto-reply trace (DA/DSR/CPR/XTVERSION/OSC responses the
/// terminal generated) of the active session, or empty when none is active.
List<Map<String, Object?>> activeTermReplyTraceSnapshot() =>
    _active?.snapshotTermReplyTrace() ?? const <Map<String, Object?>>[];

/// Grid `{cols, rows}` of the active session, or null when none is active.
Map<String, Object?>? activeGridSnapshot() => _active?.grid();

/// Clear the whole registry + active pointer (tests).
void clearAllByteRecorders() {
  _recorders.clear();
  _activeSessionId = null;
}
