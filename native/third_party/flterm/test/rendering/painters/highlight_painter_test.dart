@Tags(['ffi'])
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flterm/src/foundation.dart'
    show CellMetrics, HighlightRange, TerminalTheme;
import 'package:flterm/src/rendering/paint_state.dart';
import 'package:flterm/src/rendering/painters/highlight_painter.dart';
import 'package:flutter_test/flutter_test.dart';

/// #767 Slice B: the highlight painter must only draw a background FILL when a
/// range OPTS IN with a non-null background. A null-background range (e.g. a URL
/// anchor whose decorator is the widget-layer bubble outline) must leave the
/// glyph cells untouched — the old `?? defaultBackground` fill painted OVER and
/// HID the text. These tests render onto a known canvas color and assert the
/// covered pixels are (un)changed accordingly.
void main() {
  group('HighlightPainter background opt-in', () {
    const metrics = CellMetrics(cellWidth: 8, cellHeight: 16, baseline: 12);
    const canvasColor = ui.Color(0xFF112233); // the "text/background" beneath

    Future<ByteData> render(
      List<HighlightRange> highlights, {
      bool washSuppressed = false,
    }) async {
      final state = TerminalPaintState(TerminalTheme.dark(), metrics)
        ..cols = 4
        ..rows = 1
        ..viewportOffset = 0
        ..washSuppressed = washSuppressed
        ..highlights = highlights;

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawRect(
        const ui.Rect.fromLTWH(0, 0, 32, 16),
        ui.Paint()..color = canvasColor,
      );
      HighlightPainter(state).paint(canvas);
      final picture = recorder.endRecording();
      final image = await picture.toImage(32, 16);
      final bytes = await image.toByteData();
      picture.dispose();
      image.dispose();
      return bytes!;
    }

    int pixelArgb(ByteData bytes, {required int x, required int y}) {
      final offset = (y * 32 + x) * 4;
      final r = bytes.getUint8(offset);
      final g = bytes.getUint8(offset + 1);
      final b = bytes.getUint8(offset + 2);
      final a = bytes.getUint8(offset + 3);
      return (a << 24) | (r << 16) | (g << 8) | b;
    }

    test('a null-background range leaves the cells UNCHANGED', () async {
      final bytes = await render(const [
        HighlightRange(startRow: 0, startCol: 0, endRow: 0, endCol: 4),
      ]);
      // Sample the middle of the first cell; it must still be the canvas color.
      expect(pixelArgb(bytes, x: 4, y: 8), canvasColor.toARGB32());
    });

    test('a non-null background range FILLS the cells', () async {
      const fill = ui.Color(0xFFEE0000);
      final bytes = await render(const [
        HighlightRange(
          startRow: 0,
          startCol: 0,
          endRow: 0,
          endCol: 4,
          background: fill,
        ),
      ]);
      // Opaque fill over the canvas → the cell reads back the fill color.
      expect(pixelArgb(bytes, x: 4, y: 8), fill.toARGB32());
    });

    // #1062: while the painted offset is in flight the render box sets
    // `washSuppressed`; the painter must draw NOTHING (hide-on-scroll) even for
    // a non-null background range, so a wash whose baked absolute rows have
    // drifted off their token mid-scroll never paints a pinned/stale band.
    test('washSuppressed HIDES an otherwise-filled background range', () async {
      const fill = ui.Color(0xFFEE0000);
      final bytes = await render(
        const [
          HighlightRange(
            startRow: 0,
            startCol: 0,
            endRow: 0,
            endCol: 4,
            background: fill,
          ),
        ],
        washSuppressed: true,
      );
      // Suppressed → the cells keep the canvas color, not the fill.
      expect(pixelArgb(bytes, x: 4, y: 8), canvasColor.toARGB32());
    });
  });
}
