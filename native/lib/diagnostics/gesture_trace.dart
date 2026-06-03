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

/// One-line summary of a single gesture event for the ring buffer (#699).
///
/// Fields are fixed-key `k=v` pairs so the log is greppable and diffs cleanly:
///   pos=(dx,dy)  the raw localPosition the router received;
///   size=(w,h)   the laid-out overlay size used for the cell mapping;
///   grid=COLSxROWS  the live (cols, rows) from controller.onResize;
///   cell=(col,row)  the computed 1-based cell the mapping produced;
///   sgr=...      the SGR bytes emitted (ESC-escaped), or `none`;
///   mouse=...    the MouseTracking state name;
///   by=...       which layer handled it: `overlay` (active router) or
///                `flterm` (translucent fall-through, plain shell).
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
  return '$type '
      'pos=(${n(dx)},${n(dy)}) '
      'size=(${n(width)},${n(height)}) '
      'grid=${cols}x$rows '
      'cell=$cell '
      'sgr=$sgrText '
      'mouse=$mouseTracking '
      'by=$handledBy';
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
  while (_ring.length > gestureLogCapacity) {
    _ring.removeAt(0);
  }
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
