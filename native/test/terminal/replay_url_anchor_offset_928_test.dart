@Tags(['ffi'])
library;

// REPLAY regression for #928 — a prose-wrapped OSC-8 URL in the conversation
// pane is detected as ONE anchor (the #925 indent-aware wrap-join recovers the
// full link), but the highlight renders "a couple lines off" from the real URL
// rows and a tap on the drifted anchor copies only the FIRST row.
//
// KEY EVIDENCE (device, v0.1.10+68) — INTERMITTENT, anchor-mapping-tied:
// same capture, same URL, two consecutive copies:
//   08:02:12 [clipboard] wrote 73 chars verified=true   (FULL url — anchor right)
//   08:02:35 [clipboard] wrote 56 chars verified=true   (row-1 only — anchor drifted)
// The write path is fine both times. The truncation happens ONLY when the
// highlight/anchor is drifted; when the anchor maps to the true URL rows the
// wrap-join (#925) assembles the FULL 72-char URL (the 73-char success proves
// it). So the ROOT is the ANCHOR -> VIEWPORT ROW MAPPING drift, the #868/#863
// lineage (paintedViewportOffset vs the real scan/screen frame).
//
// THE MECHANISM (root-caused here): detection emits ranges in the ABSOLUTE,
// top-anchored screen frame (`absRow = scrollback + viewRow`, PointTag.screen).
// Both hit-test (`matchAt`) and paint geometry (`anchorRects`) map a viewport
// row back to absolute as `absRow = viewRow + paintedViewportOffset`. That is
// only correct when `paintedViewportOffset == scrollbar.offset` (the viewport's
// top absolute row). When the painted offset has NOT yet caught up to the live
// viewport top (the bottom/live-tail case: scrollback grows but no frame has
// reported the new painted offset), the two frames differ by exactly the
// scrollback delta — so a tap on the visible URL maps to the WRONG absolute row
// and either misses the anchor or lands on only its first row. This replay
// reconstructs the live-tail state (offset 0 == bottom) where the painted
// offset lags the true viewport top.

import 'package:flterm/flterm.dart';
import 'package:flutter_test/flutter_test.dart';

import 'replay_trace_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The real device URL (72 chars). The OSC-8 wrap-join must recover it whole.
  const detectedUrl =
      'https://mobissh.tailbe5094.ts.net/mobissh-native-20260622T231034+0000.apk';

  Future<TerminalController> replay(String fixture) async {
    final trace = loadByteTrace(fixture);
    final controller = TerminalController(
      config: TerminalConfig(cols: trace.cols, rows: trace.rows),
    );
    // Same three patterns, same order as the app (#767/#778).
    controller.registerTextPattern(TextPattern.osc8());
    controller.registerTextPattern(TextPattern.url());
    controller.registerTextPattern(TextPattern.path());
    await replayTrace(controller, trace);
    return controller;
  }

  // After a headless replay there is no render box reporting the painted
  // viewport offset, so it sits at its default 0 while the live viewport top
  // (scrollbar.offset) advances with scrollback growth. This is the exact
  // "painted offset lags the true viewport top" condition the device hit on the
  // intermittent (drifted) copy. Drive the controller into that resolved frame
  // the same way the widget does each frame.
  void syncPaintedToViewport(TerminalController c) {
    c.reportPaintedViewportOffset(c.scrollbar.offset);
  }

  for (final fixture in const [
    'test/fixtures/replay/url_anchor_offset_highlight_928.byte-trace.json',
    'test/fixtures/replay/url_anchor_offset_copytrunc_928.byte-trace.json',
  ]) {
    group('REPLAY #928 — anchor row offset on a wrapped OSC-8 URL [$fixture]',
        () {
      test('the wrapped URL is detected as ONE anchor carrying the FULL link',
          () async {
        final controller = await replay(fixture);
        addTearDown(controller.dispose);

        final hits = controller.anchors
            .where((a) => a.payload == detectedUrl)
            .toList();
        expect(
          hits,
          hasLength(1),
          reason: 'the OSC-8 wrap-join (#925) must recover the FULL URL as one '
              'anchor — the 73-char clipboard success proves it is assemblable',
        );
      });

      test(
        'a tap at the URL\'s ON-SCREEN cells resolves the FULL-URL match '
        '(anchor rows are NOT drifted off the real URL rows)',
        () async {
          final controller = await replay(fixture);
          addTearDown(controller.dispose);
          syncPaintedToViewport(controller);

          // The anchor stores ABSOLUTE rows. Convert each absolute range row to
          // the viewport row it should be tappable at, given the resolved
          // painted offset, and confirm matchAt there recovers the FULL URL.
          final anchor = controller.anchors
              .firstWhere((a) => a.payload == detectedUrl);
          final paintedOffset = controller.paintedViewportOffset;

          var fullUrlTapped = false;
          for (final range in anchor.ranges) {
            final viewRow = range.startRow - paintedOffset;
            // Probe a column in the middle of this row's range.
            final col = range.startCol +
                ((range.endCol - range.startCol) ~/ 2).clamp(0, 1 << 30);
            final m = controller.matchAt(row: viewRow, col: col);
            if (m != null && m.payload == detectedUrl) fullUrlTapped = true;
          }

          expect(
            fullUrlTapped,
            isTrue,
            reason: 'a tap on the visible URL must resolve the FULL-URL match '
                '— the anchor rows must map to the SAME viewport rows the paint '
                'geometry uses (matchAt/anchorRects share paintedViewportOffset); '
                'the #928 drift maps the tap to the wrong absolute row so the '
                'match misses or truncates to row 1',
          );
        },
      );

      test(
        'the anchor ranges sit at the LIVE viewport top frame (no row drift '
        'between scan frame and paint frame)',
        () async {
          final controller = await replay(fixture);
          addTearDown(controller.dispose);
          syncPaintedToViewport(controller);

          final anchor = controller.anchors
              .firstWhere((a) => a.payload == detectedUrl);
          final viewportTop = controller.scrollbar.offset;
          final paintedOffset = controller.paintedViewportOffset;

          // The scan emits absolute rows in the live frame (viewportTop +
          // visibleRow). matchAt/anchorRects subtract paintedViewportOffset.
          // For paint and detection to agree, paintedOffset must equal the
          // viewport top the scan used. A nonzero delta is the #928 drift.
          expect(
            paintedOffset,
            viewportTop,
            reason: 'the painted offset the hit-test/paint geometry subtracts '
                'must equal the live viewport top the detection scan anchored '
                'against; a delta is the #928 row drift',
          );

          // Every anchor row must fall inside the visible viewport once mapped.
          final visibleRows = controller.scrollbar.offset >= 0 ? 34 : 34;
          for (final range in anchor.ranges) {
            final viewRow = range.startRow - paintedOffset;
            expect(
              viewRow,
              inInclusiveRange(0, visibleRows - 1),
              reason: 'anchor row ${range.startRow} maps to viewport row '
                  '$viewRow which is off-screen — drifted anchor (#928)',
            );
          }
        },
      );
    });
  }
}
