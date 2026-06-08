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

import 'dart:convert';
import 'dart:typed_data';

import 'feedback_bundle.dart' show scrubSecrets;

/// Default byte-ring cap: ~256 KB of the most recent terminal output. Past this
/// the oldest chunks are evicted (backward-looking — newest always wins).
const int kByteRecorderMaxBytes = 256 * 1024;

/// Default byte-ring event cap (defense against a flood of tiny chunks blowing
/// the list length even under the byte cap).
const int kByteRecorderMaxEvents = 4096;

/// Default age cap for BOTH rings: ~30 s. Events older than this (relative to
/// the newest event) are evicted.
const Duration kByteRecorderMaxAge = Duration(seconds: 30);

/// Default scroll-ring event cap.
const int kScrollRecorderMaxEvents = 2048;

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

/// A bounded, backward-looking recorder of the raw bytes written to ONE
/// session's terminal plus its scroll-offset events. See the file header.
class SessionByteRecorder {
  SessionByteRecorder({
    this.maxBytes = kByteRecorderMaxBytes,
    this.maxEvents = kByteRecorderMaxEvents,
    this.maxAge = kByteRecorderMaxAge,
    this.maxScrollEvents = kScrollRecorderMaxEvents,
    int Function()? nowMs,
  }) : _nowMs = nowMs ?? _defaultNowMs;

  final int maxBytes;
  final int maxEvents;
  final Duration maxAge;
  final int maxScrollEvents;

  /// Monotonic relative-ms clock. Injected in tests for determinism; production
  /// uses an epoch-anchored elapsed millis.
  final int Function() _nowMs;

  // Ring buffers. Plain growable lists used as FIFO queues — eviction is from
  // the FRONT (oldest). Allocation-light: no per-event wrapper churn beyond the
  // small _ByteEvent/_ScrollEvent holders, and crucially NO byte copy/encode on
  // the hot path.
  final List<_ByteEvent> _bytes = <_ByteEvent>[];
  int _byteTotal = 0;
  final List<_ScrollEvent> _scroll = <_ScrollEvent>[];

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
      _bytes.removeAt(0);
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
      _scroll.removeAt(0);
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

/// Grid `{cols, rows}` of the active session, or null when none is active.
Map<String, Object?>? activeGridSnapshot() => _active?.grid();

/// Clear the whole registry + active pointer (tests).
void clearAllByteRecorders() {
  _recorders.clear();
  _activeSessionId = null;
}
