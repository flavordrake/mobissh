@Tags(['ffi'])
library;

// REPLAY regression for #1060 (owner P0) — on a LIVE-UPDATING multi-anchor TUI
// (the owner's Claude-Code session on the phone) the behind-glyph detection
// WASH (#1045) floated OFFSET from its pattern: a pale band sat over blank rows
// where the content USED to be, because a miss-grace anchor (#1046) — kept live
// at its old rows while an in-place repaint erased the cells under it — still
// baked its wash there. A BLOCK anchor already dodges this ("paints NO wash ...
// no stale-highlight cost"); a SPAN anchor (url/path) did not. The fix withholds
// the wash for any UNCONFIRMED (in-miss-grace) anchor — the anchor stays live so
// its gutter chip keeps #1046 continuity, only the pale band waits until the
// payload re-confirms at real cells.
//
// This trace is the owner's real byte capture (2026-07-11T20-37-14). The
// synchronous "write all bytes then settle" replay lands a CLEAN final grid and
// hides the bug — the float is MID-CHURN. So this test replays the bytes in
// TIMESTAMP order under fakeAsync (real inter-chunk gaps → real miss-grace
// windows) and asserts that at NO churn instant does a capsule wash sit over
// all-whitespace cells.

import 'dart:ui';

import 'package:fake_async/fake_async.dart';
import 'package:flterm/flterm.dart';
import 'package:flutter_test/flutter_test.dart';

import 'replay_trace_harness.dart';

const _fixture =
    'test/fixtures/replay/tui_churn_stale_wash_1060.byte-trace.json';

// The app paints a behind-glyph wash for url / osc8 / path anchors (capsule).
// Mirror that here so the fork-level replay exercises the exact wash path.
const _washPatternIds = {'url', 'osc8', 'path'};

HighlightStyle? _washResolver(StructuredMatch m) {
  if (!_washPatternIds.contains(m.patternId)) return null;
  return const HighlightStyle(background: Color(0x8800FF00), capsule: true);
}

/// Every capsule wash cell-run that currently sits over ALL-whitespace cells,
/// mapped at the given [offset]. Empty == no floating wash.
List<String> _floatingWashes(TerminalController c, int cols, int offset) {
  final visible = c.scrollbar.visible;
  final out = <String>[];
  for (final r in c.highlights) {
    if (!r.capsule) continue;
    for (var absRow = r.topRow; absRow <= r.bottomRow; absRow++) {
      final viewRow = absRow - offset;
      if (viewRow < 0 || viewRow >= visible) continue;
      final startCol = absRow == r.topRow ? r.topCol : 0;
      final endCol = absRow == r.bottomRow ? r.bottomCol : cols;
      final rowText = c.visibleRowsText(viewRow, viewRow);
      final s = startCol.clamp(0, rowText.length);
      final e = endCol.clamp(0, rowText.length);
      final slice = e > s ? rowText.substring(s, e) : '';
      if (slice.trim().isEmpty) {
        out.add('abs=$absRow view=$viewRow cols=$startCol..$endCol '
            'payload=${r.payload}');
      }
    }
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'no capsule wash floats over blank cells at ANY instant of the timed churn',
    () {
      final trace = loadByteTrace(_fixture);
      var worstFloat = <String>[];
      var floatSamples = 0;
      var suppressedForGrace = 0;

      fakeAsync((async) {
        final controller = TerminalController(
          config: TerminalConfig(cols: trace.cols, rows: trace.rows),
        )
          ..registerTextPattern(TextPattern.osc8())
          ..registerTextPattern(TextPattern.url())
          ..registerTextPattern(TextPattern.path())
          ..detectionHighlightStyleOf = _washResolver;

        var prevMs = trace.byteTrace.first.tMs;
        for (final e in trace.byteTrace) {
          final delta = e.tMs - prevMs;
          prevMs = e.tMs;
          if (delta > 0) async.elapse(Duration(milliseconds: delta));
          controller.write(lfToCrlf(e.bytes));
          // Resolve paint + hit-test against the SAME offset the fork reports as
          // painted, mirroring the render box each frame.
          final offset = controller.scrollbar.offset;
          controller.reportPaintedViewportOffset(offset);
          final floats = _floatingWashes(controller, trace.cols, offset);
          if (floats.isNotEmpty) {
            floatSamples++;
            if (floats.length > worstFloat.length) worstFloat = floats;
          }
        }
        async.elapse(const Duration(milliseconds: 2000));
        suppressedForGrace =
            controller.detectionScanStats.washSuppressedForGrace;
        controller.dispose();
      });

      expect(
        floatSamples,
        0,
        reason: 'a capsule wash sat over blank cells during churn — the #1060 '
            'floating wash. Worst instant: $worstFloat',
      );
      // The runtime path that fixes it MUST have fired on this churning trace:
      // at least one unconfirmed anchor had its wash withheld. (If this is 0 the
      // trace no longer exercises the miss-grace path and the above assertion is
      // vacuous.)
      expect(
        suppressedForGrace,
        greaterThan(0),
        reason: 'the wash-withheld-for-grace telemetry must show the fix path '
            'fired during the churn',
      );
    },
  );

  test(
    'after the churn settles, every capsule wash maps to its CURRENT glyph '
    'cells (no blank cells, no offset from the anchor rows)',
    () async {
      final trace = loadByteTrace(_fixture);
      final controller = TerminalController(
        config: TerminalConfig(cols: trace.cols, rows: trace.rows),
      )
        ..registerTextPattern(TextPattern.osc8())
        ..registerTextPattern(TextPattern.url())
        ..registerTextPattern(TextPattern.path())
        ..detectionHighlightStyleOf = _washResolver;
      addTearDown(controller.dispose);

      await replayTrace(controller, trace);
      final offset = controller.scrollbar.offset;
      controller.reportPaintedViewportOffset(offset);

      // No floating wash in the settled frame either.
      expect(
        _floatingWashes(controller, trace.cols, offset),
        isEmpty,
        reason: 'settled frame must have no wash over blank cells',
      );

      // Every ON-SCREEN capsule wash must sit on the CURRENT glyph cells of its
      // payload: the text under the wash cells must actually spell (part of) the
      // payload, not blank space or unrelated content. A stale/floating wash
      // fails this because the cells it covers no longer hold the payload.
      final visible = controller.scrollbar.visible;
      var checkedOnScreen = 0;
      for (final r in controller.highlights) {
        if (!r.capsule) continue;
        final payload = '${r.payload}';
        for (var absRow = r.topRow; absRow <= r.bottomRow; absRow++) {
          final viewRow = absRow - offset;
          if (viewRow < 0 || viewRow >= visible) continue;
          final startCol = absRow == r.topRow ? r.topCol : 0;
          final endCol = absRow == r.bottomRow ? r.bottomCol : trace.cols;
          final rowText = controller.visibleRowsText(viewRow, viewRow);
          final s = startCol.clamp(0, rowText.length);
          final e = endCol.clamp(0, rowText.length);
          final slice = (e > s ? rowText.substring(s, e) : '').trim();
          checkedOnScreen++;
          expect(slice, isNotEmpty,
              reason: 'wash at view row $viewRow for ${r.payload} covers blank '
                  'cells — stale/floating wash');
          // The covered glyphs must be part of the payload (single-row match) or
          // the payload must contain them (wrapped row) — i.e. the wash is ON
          // its text.
          expect(
            payload.contains(slice) || slice.contains(payload),
            isTrue,
            reason: 'wash at view row $viewRow covers "$slice" which is not part '
                'of its payload "$payload" — the wash drifted off its glyphs',
          );
        }
      }
      expect(checkedOnScreen, greaterThan(0),
          reason: 'the settled frame must show at least one on-screen wash');
    },
  );
}
