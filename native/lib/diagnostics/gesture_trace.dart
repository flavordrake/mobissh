// Ghostty gesture-path tracing (#699 diagnosis).
//
// The Ghostty (flterm) gesture router maps a touch pixel to a terminal cell to
// drive remote (tmux) selection/click reports. A device repro of the #699
// "selection lands several rows ABOVE the press" bug needs the EXACT numbers
// behind that mapping — raw localPosition, the laid-out overlay size, the live
// grid (cols, rows), and the computed (col, row) — to be fixed from DATA rather
// than bouncing builds off the owner's phone.
//
// Mirrors the connect_trace.dart pattern: every gesture event calls
// `gtrace(...)`, which appends a timestamped line to an in-memory ring buffer
// (`gestureLog`) AND emits to logcat tagged `[GESTURE]`. The on-device feedback
// bundle attaches `gestureLogSnapshot()` so the offset is visible off-device.
//
// SECURITY (rules/security.md / #553 contract): gesture events carry ONLY
// coordinates, sizes, grid dimensions, and SGR control bytes — never terminal
// content or credential material. The feedback assembler additionally runs every
// line through `scrubSecrets` (defense in depth). SGR bytes are rendered with the
// ESC shown as the literal text `ESC` so the line stays printable/diffable.

import 'package:flutter/foundation.dart';

/// Maximum number of lines retained by the [gestureLog] ring buffer. Older
/// lines are dropped once the cap is exceeded. Smaller than the connect log
/// (gestures fire rapidly during a drag) but large enough to hold a full
/// long-press-drag plus surrounding taps/swipes.
const int gestureLogCapacity = 120;

/// #793: the number of MOST-RECENT user-input gesture lines (swipe/scroll) the
/// ring guarantees to retain even under a flood of non-gesture churn. The real
/// #790 capture had ~68 `ghostty-resync`/resume/refit/focus lines that pushed
/// the actual `swipe-vertical` gestures out of the bounded ring. Eviction now
/// drops the oldest NON-gesture line first; a gesture line is only dropped once
/// this many newer gesture lines exist — so a resume burst can't drown swipes.
const int gestureLogGestureRetention = 32;

/// #793: a line is a protected USER-INPUT gesture (vs resync/resume/refit/focus
/// churn) iff its type token (the first whitespace-delimited word, after the
/// timestamp prefix the ring adds) starts with `swipe` or `scroll`. Pure.
bool _isProtectedGestureLine(String stored) {
  // Stored lines are `"<ts> <type> ..."`; the type is the 2nd token. A raw
  // pre-format line (no ts) has the type as the 1st token — accept either.
  for (final token in stored.split(' ')) {
    if (token.isEmpty) continue;
    // Skip a leading timestamp token (`HH:MM:SS.mmm`).
    if (token.length >= 8 && token[2] == ':' && token[5] == ':') continue;
    return token.startsWith('swipe') || token.startsWith('scroll');
  }
  return false;
}

final List<String> _ring = <String>[];

// Consecutive-duplicate suppression: a long-press-drag held still, or a stream
// of identical motion samples, collapses into the last line as ` (×N)` instead
// of flooding the ring — both on-device and in logcat.
String? _lastKey;
int _lastCount = 0;

final ValueNotifier<List<String>> _gestureLog = ValueNotifier<List<String>>(
  const <String>[],
);

/// Live, read-only view of the gesture-trace ring buffer. The newest line is
/// last. Rebuilds whenever a new trace line is appended or the log is cleared.
ValueListenable<List<String>> get gestureLog => _gestureLog;

/// Read-only snapshot of the current gesture-trace ring buffer, newest line
/// last. Returned as an unmodifiable copy so callers (e.g. the feedback bundle
/// assembler) can read the log without holding a listener or mutating the ring.
List<String> gestureLogSnapshot() => List<String>.unmodifiable(_ring);

String _timestamp(DateTime now) {
  String two(int n) => n.toString().padLeft(2, '0');
  String three(int n) => n.toString().padLeft(3, '0');
  return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}'
      '.${three(now.millisecond)}';
}

/// Render a control-byte SGR report printable: show ESC (0x1b) as the literal
/// `ESC` so a long-press-drag's `CSI<0;col;rowM` lands in the log readably and
/// never injects a raw escape into logcat. Pure.
String formatSgrForTrace(String report) =>
    report.replaceAll('\x1b', 'ESC').replaceAll('\r', '\\r');

/// One-line summary of a single gesture event for the ring buffer (#699, #723).
///
/// Fields are fixed-key `k=v` pairs so the log is greppable and diffs cleanly:
///   pos=(dx,dy)  the raw localPosition the router received;
///   size=(w,h)   the laid-out overlay box size (FULL Stack box, NOT flterm's
///                grid-sized render box — bigger by the padding + floor slack);
///   grid=COLSxROWS  the LIVE (cols, rows) from controller.onResize — flterm's
///                most recent computed grid;
///   sent=COLSxROWS  the grid LAST SENT to the PTY via sendResize — what tmux
///                ACTUALLY believes it has (#723). At steady state grid==sent;
///                a divergence here is the #723 bug (the gesture router acting on
///                a grid tmux doesn't have). Logging both side-by-side lets ONE
///                device report (correlated with the live tmux size) prove
///                live==sent==tmux convergence.
///   cell=(col,row)  the computed 1-based cell the mapping produced;
///   sgr=...      the SGR bytes emitted (ESC-escaped), or `none`;
///   mouse=...    the MouseTracking state name;
///   by=...       which layer handled it: `overlay` (active router) or
///                `flterm` (translucent fall-through, plain shell).
///
/// [sentCols]/[sentRows] default to [cols]/[rows] so callers that don't track a
/// last-sent grid (and existing tests) keep the in-sync `sent==grid` line.
///
/// Pure (no I/O), so the formatting is unit-testable headless.
String formatGestureEvent({
  required String type,
  required double dx,
  required double dy,
  required double width,
  required double height,
  required int cols,
  required int rows,
  int? sentCols,
  int? sentRows,
  int? col,
  int? row,
  String? sgr,
  required String mouseTracking,
  required String handledBy,
}) {
  String n(double v) => v.toStringAsFixed(1);
  final cell = (col != null && row != null) ? '($col,$row)' : '-';
  final sgrText = (sgr != null && sgr.isNotEmpty)
      ? formatSgrForTrace(sgr)
      : 'none';
  final sCols = sentCols ?? cols;
  final sRows = sentRows ?? rows;
  return '$type '
      'pos=(${n(dx)},${n(dy)}) '
      'size=(${n(width)},${n(height)}) '
      'grid=${cols}x$rows '
      'sent=${sCols}x$sRows '
      'cell=$cell '
      'sgr=$sgrText '
      'mouse=$mouseTracking '
      'by=$handledBy';
}

/// #793: cap the ring to [gestureLogCapacity], but protect recent user-input
/// gesture lines (swipe/scroll) from a non-gesture flood. While over capacity,
/// evict the OLDEST non-protected line. If none remains to evict (the ring is
/// all protected gestures), evict the oldest protected line — but only the ones
/// beyond [gestureLogGestureRetention] newest, so the most recent swipes win and
/// the protected segment is itself bounded. Allocation-light: a single forward
/// scan per eviction, no copies.
void _capRing() {
  while (_ring.length > gestureLogCapacity) {
    var evictAt = -1;
    // Prefer the oldest NON-protected (churn) line.
    for (var i = 0; i < _ring.length; i++) {
      if (!_isProtectedGestureLine(_ring[i])) {
        evictAt = i;
        break;
      }
    }
    if (evictAt < 0) {
      // All lines are protected gestures — drop the oldest so the newest
      // [gestureLogGestureRetention] survive (bounded protected segment).
      evictAt = 0;
    }
    _ring.removeAt(evictAt);
  }
  // Bound the protected segment too: keep only the newest
  // [gestureLogGestureRetention] protected lines so an endless swipe stream
  // can't itself grow unbounded within the capacity.
  var protectedCount = 0;
  for (var i = _ring.length - 1; i >= 0; i--) {
    if (!_isProtectedGestureLine(_ring[i])) continue;
    protectedCount++;
    if (protectedCount > gestureLogGestureRetention) {
      _ring.removeAt(i);
    }
  }
}

/// Append a raw pre-formatted gesture line to the ring (and logcat). Most call
/// sites use [gevent] instead; this is the low-level primitive (and what the
/// duplicate-collapse logic keys on).
void gtrace(String line) {
  final ts = _timestamp(DateTime.now());

  // Collapse a run of identical lines into the most recent entry as ` (×N)`.
  if (line == _lastKey && _ring.isNotEmpty) {
    _lastCount++;
    _ring[_ring.length - 1] = '$ts $line (×$_lastCount)';
    _gestureLog.value = List<String>.unmodifiable(_ring);
    return;
  }

  _lastKey = line;
  _lastCount = 1;
  debugPrint('[GESTURE]$line');

  _ring.add('$ts $line');
  _capRing();
  _gestureLog.value = List<String>.unmodifiable(_ring);
}

/// Record one gesture event (the common entry point). Formats via
/// [formatGestureEvent] then appends via [gtrace].
void gevent({
  required String type,
  required double dx,
  required double dy,
  required double width,
  required double height,
  required int cols,
  required int rows,
  int? sentCols,
  int? sentRows,
  int? col,
  int? row,
  String? sgr,
  required String mouseTracking,
  required String handledBy,
}) {
  gtrace(
    formatGestureEvent(
      type: type,
      dx: dx,
      dy: dy,
      width: width,
      height: height,
      cols: cols,
      rows: rows,
      sentCols: sentCols,
      sentRows: sentRows,
      col: col,
      row: row,
      sgr: sgr,
      mouseTracking: mouseTracking,
      handledBy: handledBy,
    ),
  );
}

/// Clears the on-device gesture-log ring buffer. Does not affect logcat.
void clearGestureLog() {
  _ring.clear();
  _lastKey = null;
  _lastCount = 0;
  _gestureLog.value = const <String>[];
}
