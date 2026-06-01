// Per-session PTY signal detector (#575).
//
// Scans a session's output stream for "attention" signals the remote emits:
//   - OSC 9  (ESC ] 9 ; <message> BEL | ST) — the iTerm/desktop-notification
//     convention the PWA already uses (notify-bell.sh emits OSC 9). Carries a
//     human message.
//   - the terminal BEL (\a / 0x07) as a fallback attention signal (no message).
//
// One detector per session (keyed by sessionId at the call site). Escape
// sequences can be split across PTY chunks, so the detector buffers the partial
// tail across [feed] calls. It emits a [SessionSignal] which the task isolate
// turns into a tappable notification via [SessionNotification].
//
// This is intentionally a SMALL, single-pass scanner — the shared
// SessionStreamParser the issue mentions (path/URL detection for #570) can grow
// from this seam, but #575 only needs OSC-9 + BEL.

import 'dart:typed_data';

import 'session_notification.dart';

/// A detected attention signal from a session's output stream.
class SessionSignal {
  const SessionSignal({required this.kind, this.message});

  final SessionSignalKind kind;

  /// The OSC-9 message text, or null for a bare BEL.
  final String? message;
}

const int _esc = 0x1b; // ESC
const int _bel = 0x07; // BEL / \a
const int _backslash = 0x5c; // '\' (ST is ESC \)
const int _bracket = 0x5d; // ']'

/// Scans PTY bytes for OSC-9 / BEL signals, buffering across chunk boundaries.
class SessionSignalDetector {
  SessionSignalDetector({required this.onSignal, this.maxBuffer = 4096});

  /// Invoked once per detected signal.
  final void Function(SessionSignal signal) onSignal;

  /// Cap on the carry-over buffer so a stream that never terminates an OSC
  /// sequence can't grow unbounded. When exceeded we drop the oldest bytes.
  final int maxBuffer;

  /// Carry-over bytes from a partial escape sequence at the end of the last
  /// feed. Empty most of the time.
  final List<int> _buf = [];

  /// Feed a chunk of PTY output. Emits zero or more signals.
  void feed(Uint8List chunk) {
    _buf.addAll(chunk);
    _scan();
    // Bound the buffer: if an OSC start never terminates, keep only the tail.
    if (_buf.length > maxBuffer) {
      _buf.removeRange(0, _buf.length - maxBuffer);
    }
  }

  void _scan() {
    var i = 0;
    while (i < _buf.length) {
      final byte = _buf[i];
      if (byte == _esc) {
        // Possible OSC: ESC ] 9 ; ... (BEL | ESC \)
        final consumed = _tryOsc9(i);
        if (consumed == _needMore) {
          // Incomplete escape — keep everything from `i` onward for next feed.
          _buf.removeRange(0, i);
          return;
        }
        if (consumed > 0) {
          _buf.removeRange(0, consumed);
          i = 0;
          continue;
        }
        // Not an OSC 9 we handle — skip the ESC and keep scanning.
        i += 1;
        continue;
      }
      if (byte == _bel) {
        // Standalone BEL → fallback attention signal.
        onSignal(const SessionSignal(kind: SessionSignalKind.ready));
        _buf.removeRange(0, i + 1);
        i = 0;
        continue;
      }
      i += 1;
    }
    // Reaching here means no pending partial sequence; nothing buffered is
    // mid-escape, so we can drop everything scanned (no signal bytes remain).
    _buf.clear();
  }

  /// Sentinel: the sequence starting at the scan index is an OSC that hasn't
  /// terminated yet — wait for more bytes.
  static const int _needMore = -1;

  /// Try to parse an OSC 9 sequence starting at [start] (which is the ESC).
  /// Returns the number of bytes consumed (start..terminator inclusive) on a
  /// successful parse (and fires [onSignal]); 0 when this ESC does not begin an
  /// OSC 9 we handle; [_needMore] when the sequence is incomplete.
  int _tryOsc9(int start) {
    // Need at least ESC ] 9 ;
    if (start + 1 >= _buf.length) return _needMore;
    if (_buf[start + 1] != _bracket) return 0; // not an OSC at all
    if (start + 2 >= _buf.length) return _needMore;
    if (_buf[start + 2] != 0x39 /* '9' */ ) return 0; // OSC but not 9
    if (start + 3 >= _buf.length) return _needMore;
    if (_buf[start + 3] != 0x3b /* ';' */ ) return 0;

    // Collect the message until BEL or ST (ESC \).
    final msg = <int>[];
    var j = start + 4;
    while (j < _buf.length) {
      final b = _buf[j];
      if (b == _bel) {
        _emitOsc(msg);
        return (j - start) + 1;
      }
      if (b == _esc) {
        if (j + 1 >= _buf.length) return _needMore; // maybe ST split
        if (_buf[j + 1] == _backslash) {
          _emitOsc(msg);
          return (j - start) + 2;
        }
        // ESC not followed by \ inside an OSC — malformed; stop the sequence.
        return 0;
      }
      msg.add(b);
      j += 1;
    }
    return _needMore; // ran out of bytes before a terminator
  }

  void _emitOsc(List<int> msgBytes) {
    final text = String.fromCharCodes(msgBytes).trim();
    onSignal(
      SessionSignal(
        kind: SessionSignalKind.ready,
        message: text.isEmpty ? null : text,
      ),
    );
  }
}
