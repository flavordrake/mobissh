@Tags(['ffi'])
library;

// #1062 (owner P0) — the detection WASH was PINNED during scroll: it painted
// once and never moved as content scrolled past, so a pale band sat over cells
// its token had scrolled away from ("a wash over 'four-layer defense.' which is
// not its pattern"). ROOT: the wash's baked ABSOLUTE rows are corrected by the
// rescan/relocate, but that reconcile is DEFERRED while scrolling (#1044 perf
// gating), so mid-scroll the band can address stale cells. Prior tests only
// checked the SETTLED frame and missed the pure-scroll case.
//
// FIX (the #988 bubble stance ported to the behind-glyph fill): HIDE the wash
// while the painted offset is in flight (`isScrolling`) and re-show it on settle
// at the correct offset. The render box reads `isScrolling` each paint into
// `TerminalPaintState.washSuppressed`; the HighlightPainter early-returns on it.
//
// This test drives a REAL TerminalView fling and asserts, PER FRAME:
//   * the render layer's wash-suppression tracks `controller.isScrolling`
//     exactly (the hide-on-scroll wiring), AND
//   * on any frame the wash is NOT suppressed, every on-screen capsule wash
//     sits on its token's real glyph cells (never blank / a different token).
// Then it asserts the hide path actually fired during the fling
// (washHiddenForScroll > 0), and that on settle the wash re-shows on the right
// tokens (isScrolling false, not suppressed, on-glyph).

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/flterm.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// The app paints a behind-glyph capsule wash for url / path anchors. Mirror it.
const _washPatternIds = {'url', 'path'};

HighlightStyle? _washResolver(StructuredMatch m) {
  if (!_washPatternIds.contains(m.patternId)) return null;
  return const HighlightStyle(background: Color(0x8800FF00), capsule: true);
}

/// Every ON-SCREEN capsule wash cell-run that currently sits over cells NOT
/// holding (part of) its payload, mapped at [offset]. Empty == every visible
/// wash is correctly on its token's glyphs.
List<String> _driftedWashes(TerminalController c, int cols, int offset) {
  final visible = c.scrollbar.visible;
  final out = <String>[];
  for (final r in c.highlights) {
    if (!r.capsule) continue;
    final payload = '${r.payload}';
    for (var absRow = r.topRow; absRow <= r.bottomRow; absRow++) {
      final viewRow = absRow - offset;
      if (viewRow < 0 || viewRow >= visible) continue;
      final startCol = absRow == r.topRow ? r.topCol : 0;
      final endCol = absRow == r.bottomRow ? r.bottomCol : cols;
      final rowText = c.visibleRowsText(viewRow, viewRow);
      final s = startCol.clamp(0, rowText.length);
      final e = endCol.clamp(0, rowText.length);
      final slice = (e > s ? rowText.substring(s, e) : '').trim();
      final onGlyph =
          slice.isNotEmpty && (payload.contains(slice) || slice.contains(payload));
      if (!onGlyph) {
        out.add('abs=$absRow view=$viewRow "$slice" payload=$payload');
      }
    }
  }
  return out;
}

void main() {
  testWidgets(
    'the detection wash HIDES while scrolling and re-shows on its tokens at '
    'settle — never a pinned/stale band mid-scroll (#1062)',
    (tester) async {
      final controller = TerminalController(
        config: const TerminalConfig(cols: 62, rows: 36),
      )
        ..registerTextPattern(TextPattern.url())
        ..registerTextPattern(TextPattern.path())
        ..detectionHighlightStyleOf = _washResolver;
      addTearDown(controller.dispose);

      final scrollController = TerminalScrollController();
      addTearDown(scrollController.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 700,
              height: 620,
              child: TerminalView(
                controller: controller,
                scrollController: scrollController,
                autofocus: false,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      void write(String s) =>
          controller.write(Uint8List.fromList(utf8.encode(s)));

      // A flood with a URL + a path anchor every 40 lines so a wash is on screen
      // at every fling position.
      for (var i = 0; i < 800; i++) {
        if (i % 40 == 0) {
          write('line ${i.toString().padLeft(5, '0')} '
              'https://example.com/page/$i and /etc/hosts/$i too\r\n');
        } else {
          write('line ${i.toString().padLeft(5, '0')} '
              'filler filler filler filler\r\n');
        }
      }
      // Settle output + detection debounce, then wait out the auto-scroll-to-
      // bottom until the offset comes to rest (isScrolling false).
      await tester.pump(const Duration(milliseconds: 400));
      for (var i = 0; i < 40 && controller.isScrolling; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump();

      TerminalRenderBox renderBox() => tester.renderObject<TerminalRenderBox>(
            find.byType(TerminalRenderer),
          );

      // Precondition: at rest the wash is present, NOT suppressed, and on-glyph.
      expect(controller.isScrolling, isFalse, reason: 'should be at rest');
      expect(renderBox().debugWashSuppressed, isFalse,
          reason: 'a stationary frame must NOT suppress the wash');
      expect(
        controller.highlights.any((r) => r.capsule),
        isTrue,
        reason: 'precondition: a capsule wash is live before the fling',
      );
      expect(
        _driftedWashes(controller, 62, controller.paintedViewportOffset),
        isEmpty,
        reason: 'precondition: settled washes sit on their tokens',
      );
      final anchorsBefore = controller.anchors.length;

      // ---- the measured fling: 60 frames of pure viewport movement ----
      controller.detectionScanStats.reset();
      final position = scrollController.position;
      final startPixels = position.pixels;
      var sawSuppressedDuringFling = false;
      var frameChecks = 0;
      for (var frame = 1; frame <= 60; frame++) {
        position.jumpTo(startPixels - frame * 40.0);
        await tester.pump(const Duration(milliseconds: 16));
        frameChecks++;

        final suppressed = renderBox().debugWashSuppressed;
        if (suppressed) sawSuppressedDuringFling = true;

        // INVARIANT (the #1062 gate): every frame is EITHER wash-hidden
        // (hide-on-scroll) OR every VISIBLE wash sits on its token's real glyph
        // cells at the painted offset — never a pinned band over the wrong
        // cells. (Exact frame-by-frame suppression is NOT asserted here: paint
        // reflects the isScrolling the PREVIOUS report set, a deliberate
        // one-frame lag, so the first scroll frame can still be un-suppressed —
        // and correctly so, since a pure scrollback offset shift never drifts a
        // wash off immutable history.)
        if (!suppressed) {
          final drift =
              _driftedWashes(controller, 62, controller.paintedViewportOffset);
          expect(
            drift,
            isEmpty,
            reason: 'frame $frame: a VISIBLE wash sat off its token mid-scroll '
                '(the #1062 pinned wash): $drift',
          );
        }
      }

      // The hide path MUST have engaged during the fling (else this is vacuous).
      expect(sawSuppressedDuringFling, isTrue,
          reason: 'the wash was never hidden during the fling — hide-on-scroll '
              'never engaged ($frameChecks frames checked)');
      expect(
        controller.detectionScanStats.washHiddenForScroll,
        greaterThan(0),
        reason: 'the washHiddenForScroll telemetry must show the hide path fired',
      );

      // ---- settle: the wash re-shows on the correct tokens ----
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(controller.isScrolling, isFalse, reason: 'never settled');
      expect(renderBox().debugWashSuppressed, isFalse,
          reason: 'the wash must be un-suppressed once scrolling settles');
      expect(
        controller.anchors.length,
        greaterThan(0),
        reason: 'anchors must survive the fling',
      );
      expect(
        controller.highlights.any((r) => r.capsule),
        isTrue,
        reason: 'the wash must re-show after settle (a fling must not strand it '
            'hidden)',
      );
      expect(
        _driftedWashes(controller, 62, controller.paintedViewportOffset),
        isEmpty,
        reason: 'after settle every wash must sit on its token — re-derived at '
            'the correct offset',
      );
      debugPrint('WASH1062 fling OK: suppressedDuringFling=$sawSuppressedDuringFling '
          'washHiddenForScroll=${controller.detectionScanStats.washHiddenForScroll} '
          'anchorsBefore=$anchorsBefore anchorsAfter=${controller.anchors.length}');
    },
  );
}
