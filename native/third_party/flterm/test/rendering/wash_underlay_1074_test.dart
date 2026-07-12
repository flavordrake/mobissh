@Tags(['ffi'])
library;

// #1074 — the COMPOSITE the app's live wash layer relies on: a wash capsule
// painted UNDERNEATH a TRANSPARENT-background terminal (backgroundOpacity 0)
// shows THROUGH on default-background cells (behind the glyphs) and is OCCLUDED
// by explicit-background cells. This is the fork half of the relocation — it
// exercises the REAL renderer over a real wash capsule (highlightCapsuleRRect),
// asserting compositing by PIXEL SAMPLING (not a golden — goldens here are pinned
// to the CI container image; solid-fill pixel samples are host-independent).
//
// The app's GhosttyWashLayer paints these capsules; here a plain CustomPaint
// stands in for it so the test stays inside the fork (no app import). The
// terminal itself draws NO wash (observer highlights = []): the whole point of
// #1074 is that the wash is NOT in the paint cycle.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/src/foundation.dart';
import 'package:flterm/src/rendering.dart';
import 'package:flterm/src/rendering/terminal_render_cache.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart';

import 'helpers/font_loader.dart';

void main() {
  setUpAll(loadBundledFonts);

  group('#1074 wash underlay composite', () {
    const cols = 12;
    const rows = 3;
    // Big cells so a cell-background sample lands clear of glyph ink.
    const metrics = CellMetrics(cellWidth: 16, cellHeight: 24, baseline: 18);
    const backdrop = Color(0xFF000000); // solid black backdrop (app-owned)
    const washColor = Color(0xFF3040FF); // the wash fill (blue) — under the term
    const explicitBg = '\x1b[48;2;40;200;80m'; // green explicit background
    final sceneKey = GlobalKey();

    // A default-bg SPACE cell on the URL row (col 8: after "http://a"), fully
    // clear of glyph ink, so its centre samples the wash showing through.
    const urlRow = 0;
    const spaceCol = 8;
    // A green explicit-bg SPACE cell on row 1, col 0.
    const bgRow = 1;
    const bgCol = 0;

    Rect cellRange(int row, int startCol, int endCol) => Rect.fromLTWH(
          startCol * metrics.cellWidth,
          row * metrics.cellHeight,
          (endCol - startCol) * metrics.cellWidth,
          metrics.cellHeight,
        );

    TerminalRenderCache renderCache() {
      final cache = TerminalRenderCache();
      addTearDown(cache.dispose);
      return cache;
    }

    Future<({ByteData bytes, int width})> pumpAndCapture(
        WidgetTester tester) async {
      final terminal = Terminal(cols: cols, rows: rows);
      addTearDown(terminal.dispose);
      // Row 0: a URL + a trailing space (the sampled default-bg cell). Row 1: a
      // single green explicit-bg space cell (the occlusion sample).
      terminal.write(Uint8List.fromList(
        utf8.encode('http://a \r\n$explicitBg \x1b[0m'),
      ));

      final theme = TerminalTheme.dark().copyWith(
        fontFamilyFallback: bundledFontFamilyFallback,
        // #1074: transparent terminal — the backdrop + wash below show through.
        backgroundOpacity: 0.0,
        backgroundOpacityCells: false,
      );

      tester.view.devicePixelRatio = 1.0;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: cols * metrics.cellWidth,
              height: rows * metrics.cellHeight,
              child: RepaintBoundary(
                key: sceneKey,
                child: Stack(
                  children: [
                    // Bottom: solid backdrop (the app's ColoredBox(theme.bg)).
                    const Positioned.fill(child: ColoredBox(color: backdrop)),
                    // The wash layer: capsules over the URL row AND the green
                    // cell, so the green cell's occlusion is a real test.
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _WashPainter([
                          cellRange(urlRow, 0, 9),
                          cellRange(bgRow, bgCol, bgCol + 1),
                        ], washColor),
                      ),
                    ),
                    // Top: the TRANSPARENT terminal (backgroundOpacity 0). The
                    // app wraps the renderer in a ColoredBox tinted by opacity —
                    // at 0 that is fully transparent, so the wash shows through.
                    Positioned.fill(
                      child: ColoredBox(
                        color: theme.background
                            .withValues(alpha: theme.backgroundOpacity),
                        child: TerminalRenderer(
                          terminal: terminal,
                          theme: theme,
                          metrics: metrics,
                          offset: ViewportOffset.zero(),
                          renderCache: renderCache(),
                          renderObserver: const _Observer(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      // A single extra pump composites the terminal frame. NO pumpAndSettle: the
      // cursor blink schedules periodic timers that never settle.
      await tester.pump();
      final boundary =
          sceneKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      // toImage / toByteData complete on real event-loop tasks the fake test
      // clock does not drive — run them under runAsync so they actually resolve.
      late ByteData bytes;
      late int width;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        width = image.width;
        bytes = (await image.toByteData())!;
        image.dispose();
      });
      return (bytes: bytes, width: width);
    }

    ({int r, int g, int b}) sample(ByteData bytes, int width, int x, int y) {
      final i = (y * width + x) * 4;
      return (
        r: bytes.getUint8(i),
        g: bytes.getUint8(i + 1),
        b: bytes.getUint8(i + 2),
      );
    }

    testWidgets('default-bg cell shows the wash THROUGH; explicit-bg OCCLUDES',
        (tester) async {
      final (:bytes, :width) = await pumpAndCapture(tester);

      int cx(int col) =>
          (col * metrics.cellWidth + metrics.cellWidth / 2).round();
      int cy(int row) =>
          (row * metrics.cellHeight + metrics.cellHeight / 2).round();

      // Default-bg space cell centre on the URL row → the blue wash shows
      // through the transparent terminal over the black backdrop.
      final through = sample(bytes, width, cx(spaceCol), cy(urlRow));
      expect(through.b, greaterThan(180),
          reason: 'wash blue shows through default-bg: $through');
      expect(through.b, greaterThan(through.r + 60));
      expect(through.b, greaterThan(through.g + 60));

      // Explicit green-bg cell centre → opaque green OCCLUDES the blue wash.
      final occluded = sample(bytes, width, cx(bgCol), cy(bgRow));
      expect(occluded.g, greaterThan(140),
          reason: 'explicit green bg occludes the wash: $occluded');
      expect(occluded.g, greaterThan(occluded.b + 40),
          reason: 'green dominates — the blue wash is hidden: $occluded');
    });
  });
}

/// Stand-in for the app's GhosttyWashLayer: fills each [rects] entry as a wash
/// capsule (the fork's highlightCapsuleRRect geometry) in [color].
class _WashPainter extends CustomPainter {
  _WashPainter(this.rects, this.color);

  final List<Rect> rects;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.fill
      ..color = color;
    for (final rect in rects) {
      canvas.drawRRect(
        highlightCapsuleRRect(rect, roundLeft: true, roundRight: true),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WashPainter old) =>
      old.color != color || old.rects != rects;
}

class _Observer implements TerminalRenderObserver {
  const _Observer();

  @override
  bool get hasFocus => true;

  @override
  TerminalSelection? get selection => null;

  // #1074: the terminal draws NO wash — the app layer does, below it.
  @override
  List<HighlightRange> get highlights => const [];

  @override
  void reportPaintedViewportOffset(int offset) {}

  @override
  bool get isScrolling => false;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}
