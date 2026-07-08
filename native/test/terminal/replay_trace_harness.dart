// REPLAY HARNESS (#791): turn a captured bug-report byte+scroll trace into a
// deterministic, headless reproduction against a REAL flterm TerminalController.
//
// The #790/#793 in-app recorder captures the raw PTY byte stream plus the user's
// scroll gestures and the server saves them as `${ts}-bug-report.byte-trace.json`:
//
//   { "grid": {"cols": C, "rows": R},
//     "byteTrace":   [ {"tMs": <ms>, "b64": <base64 of a raw chunk>}, ... ],
//     "scrollTrace": [ {"tMs": <ms>, "offset": <rows-from-top>}, ... ],
//     "sentSgrTrace": [ ... ]  // OPTIONAL, recorder v2 (#793). Tolerated if absent.
//   }
//
// Mirrors the loader shape of `replay_url_detection_test.dart` (`loadCast` /
// `_lfToCrlf`) so the two replay tiers share one mental model: the bytes ARE the
// real grid, captured once from a real device into a fixture, and replaying them
// into `controller.write(...)` runs the real libghostty VT parser headlessly
// under `flutter test` on the host VM (ffi-tagged) — no emulator, no SSH, no
// socket. A reported repro thus becomes a permanent every-commit regression test.
//
// THE LOOP:
//   1. Owner long-presses Feedback on a recorder-enabled build → trace uploads,
//      server saves `${ts}-bug-report.byte-trace.json`.
//   2. Drop that file into `native/test/fixtures/replay/`.
//   3. Add a test that `loadByteTrace(...)` + `replayTrace(...)` + asserts the
//      render-relevant state the bug is about (scroll offset honored, scrollback
//      extent, cursor/anchor placement, extracted grid content).
//   4. Fix the bug at the source; the replayed trace pins it forever.
//
// See `native/test/fixtures/replay/README.md` for the full pattern.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flterm/flterm.dart';

/// One timestamped raw byte chunk from a captured `byteTrace`.
class ByteEvent {
  ByteEvent(this.tMs, this.bytes);

  /// Capture-relative timestamp in milliseconds (monotonic, ascending).
  final int tMs;

  /// The raw PTY bytes for this chunk (already base64-decoded).
  final Uint8List bytes;
}

/// One timestamped scroll position from a captured `scrollTrace`.
class ScrollEvent {
  ScrollEvent(this.tMs, this.offset);

  /// Capture-relative timestamp in milliseconds.
  final int tMs;

  /// Viewport offset in ROWS from the top of scrollback at this instant.
  final int offset;
}

/// One captured input/SGR event from a recorder-v2 (#793) `sentSgrTrace`.
///
/// Kept opaque on purpose: the v2 schema may carry encoded mouse/SGR bytes or a
/// label. The harness preserves them so a future scroll-gesture replay tier can
/// consume them, but the headless tier does not require them.
class SgrEvent {
  SgrEvent(this.tMs, this.raw);

  /// Capture-relative timestamp in milliseconds.
  final int tMs;

  /// The raw decoded map for this event (schema not yet frozen).
  final Map<String, dynamic> raw;
}

/// A captured bug-report trace: grid size + ordered byte/scroll (+ optional SGR)
/// events. The deterministic input to [replayTrace].
class BugReportTrace {
  BugReportTrace({
    required this.cols,
    required this.rows,
    required this.byteTrace,
    required this.scrollTrace,
    this.sentSgrTrace = const [],
  });

  /// Captured grid columns.
  final int cols;

  /// Captured grid rows.
  final int rows;

  /// Raw byte chunks, ascending by [ByteEvent.tMs].
  final List<ByteEvent> byteTrace;

  /// Scroll positions, ascending by [ScrollEvent.tMs].
  final List<ScrollEvent> scrollTrace;

  /// Optional recorder-v2 (#793) input/SGR events. Empty when the fixture
  /// predates v2.
  final List<SgrEvent> sentSgrTrace;

  /// The final scroll offset the user settled on, or null when no scroll was
  /// recorded. This is the offset [replayTrace] restores after ingesting bytes.
  int? get finalScrollOffset =>
      scrollTrace.isEmpty ? null : scrollTrace.last.offset;
}

/// Map bare LF to CRLF so a captured row returns to column 0 when written to the
/// terminal. Idempotent: an existing CR before an LF is not doubled — a raw PTY
/// stream that is already CRLF passes through unchanged. Mirrors the helper in
/// `replay_url_detection_test.dart`.
Uint8List lfToCrlf(Uint8List bytes) {
  final out = <int>[];
  var prev = 0;
  for (final b in bytes) {
    if (b == 0x0a && prev != 0x0d) out.add(0x0d);
    out.add(b);
    prev = b;
  }
  return Uint8List.fromList(out);
}

/// Parse a captured bug-report byte-trace JSON file into a [BugReportTrace].
///
/// Mirrors `loadCast` in `replay_url_detection_test.dart`. Events are sorted by
/// `tMs` so replay order is deterministic regardless of file order. The optional
/// `sentSgrTrace` (recorder v2 #793) is parsed when present and ignored when
/// absent — this real fixture predates it.
BugReportTrace loadByteTrace(String path) {
  return parseByteTrace(File(path).readAsStringSync());
}

/// Parse a bug-report byte-trace from its raw JSON [source] string. The
/// string-input seam exists for the ON-DEVICE paint replay tier
/// (`integration_test/paint_replay_test.dart`), which embeds the fixture as a
/// Dart constant because the emulator has no access to repo files.
BugReportTrace parseByteTrace(String source) {
  final json = jsonDecode(source) as Map<String, dynamic>;
  final grid = json['grid'] as Map<String, dynamic>;

  final byteTrace = [
    for (final e in (json['byteTrace'] as List).cast<Map<String, dynamic>>())
      ByteEvent(e['tMs'] as int, base64Decode(e['b64'] as String)),
  ]..sort((a, b) => a.tMs.compareTo(b.tMs));

  final scrollTrace = [
    for (final e
        in ((json['scrollTrace'] as List?) ?? const [])
            .cast<Map<String, dynamic>>())
      ScrollEvent(e['tMs'] as int, e['offset'] as int),
  ]..sort((a, b) => a.tMs.compareTo(b.tMs));

  final sentSgrTrace = [
    for (final e
        in ((json['sentSgrTrace'] as List?) ?? const [])
            .cast<Map<String, dynamic>>())
      SgrEvent(e['tMs'] as int, e),
  ]..sort((a, b) => a.tMs.compareTo(b.tMs));

  return BugReportTrace(
    cols: grid['cols'] as int,
    rows: grid['rows'] as int,
    byteTrace: byteTrace,
    scrollTrace: scrollTrace,
    sentSgrTrace: sentSgrTrace,
  );
}

/// Replay [trace] into [controller] in timestamp order, then restore the user's
/// final scroll offset.
///
/// Writes every `byteTrace` chunk through `controller.write` (LF→CRLF normalized,
/// idempotent) so the real libghostty parser builds the exact captured grid +
/// scrollback. After all bytes are ingested, applies the final `scrollTrace`
/// offset so the viewport sits where the user left it — the position a scroll-
/// render bug (#789 scroll-stuck, #772 cursor block) manifests at. An offset of 0
/// (or no scroll) means the viewport stays at the bottom (live tail).
///
/// Returns after the detection re-scan debounce settles (mirrors the 250ms in
/// the URL detection replay) so anchor/highlight assertions are stable.
Future<void> replayTrace(
  TerminalController controller,
  BugReportTrace trace,
) async {
  for (final e in trace.byteTrace) {
    controller.write(lfToCrlf(e.bytes));
  }

  // Apply the user's final scroll position. The recorder stores an offset in
  // rows from the top of scrollback; the controller exposes scrollToTop /
  // scrollToBottom plus a live `scrollbar.offset`. Offset 0 with content present
  // means "top of history" only if the user scrolled up; the recorder emits the
  // resting offset, so reproduce it precisely where the API allows.
  final offset = trace.finalScrollOffset;
  if (offset != null && offset > 0) {
    // A non-zero resting offset means the user scrolled UP into history. The
    // public controller has no absolute "scroll to row N" setter, so reproduce
    // the top-of-history anchor (the #789 scroll-stuck condition is "scrolled up,
    // then snapped back"); the harness then asserts the offset is honored and
    // queryable. A future widget tier replays the gesture stream for pixel-exact
    // mid-history offsets. Offset 0 (or no scroll) leaves the viewport at the
    // live tail, which is where bytes already left it — no action needed.
    controller.scrollToTop();
  }

  // Detection re-scan is debounced (~120ms); mirror the URL replay's 250ms so
  // anchors/highlights have settled before assertions read them.
  await Future<void>.delayed(const Duration(milliseconds: 250));
}

/// Builds a controller sized to [trace]'s captured grid and replays it. Convenience
/// wrapper over [replayTrace]; the caller owns disposal.
Future<TerminalController> replayIntoNewController(BugReportTrace trace) async {
  final controller = TerminalController(
    config: TerminalConfig(cols: trace.cols, rows: trace.rows),
  );
  await replayTrace(controller, trace);
  return controller;
}
