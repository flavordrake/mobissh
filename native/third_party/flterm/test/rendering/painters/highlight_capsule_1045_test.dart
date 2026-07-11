@Tags(['ffi'])
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flterm/src/foundation.dart'
    show
        CellMetrics,
        HighlightRange,
        TerminalTheme,
        highlightCapsuleRRect,
        kHighlightCapsuleBottomOutset,
        kHighlightCapsulePadX,
        kHighlightCapsuleTopInset;
import 'package:flterm/src/rendering/paint_state.dart';
import 'package:flterm/src/rendering/painters/highlight_painter.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1045: the detection wash moves INTO the fork's highlight paint pass so it
/// renders BEHIND the glyphs. The capsule LOOK (#988/#1000 — content-hugging
/// per-row fills, rounded caps ONLY on the true first/last rows, the pad/inset
/// polish) is ported from the retired widget-layer bubble into
/// [HighlightPainter] behind the per-range capsule flags. These tests pin the
/// pure geometry helper and pixel-probe the painter's capsule branch.
void main() {
  group('highlightCapsuleRRect geometry', () {
    const cell = ui.Rect.fromLTWH(8, 0, 16, 16);

    test('pads horizontally, insets the top slack, outsets past descenders',
        () {
      final rrect =
          highlightCapsuleRRect(cell, roundLeft: true, roundRight: true);
      expect(rrect.left, cell.left - kHighlightCapsulePadX);
      expect(rrect.right, cell.right + kHighlightCapsulePadX);
      expect(rrect.top, cell.top + kHighlightCapsuleTopInset);
      expect(rrect.bottom, cell.bottom + kHighlightCapsuleBottomOutset);
    });

    test('rounds ONLY the requested ends (capsule radius = half height)', () {
      final both =
          highlightCapsuleRRect(cell, roundLeft: true, roundRight: true);
      final radius = both.height / 2;
      expect(both.tlRadiusX, radius);
      expect(both.blRadiusX, radius);
      expect(both.trRadiusX, radius);
      expect(both.brRadiusX, radius);

      final leftOnly =
          highlightCapsuleRRect(cell, roundLeft: true, roundRight: false);
      expect(leftOnly.tlRadiusX, radius);
      expect(leftOnly.blRadiusX, radius);
      expect(leftOnly.trRadiusX, 0);
      expect(leftOnly.brRadiusX, 0);

      final middle =
          highlightCapsuleRRect(cell, roundLeft: false, roundRight: false);
      expect(middle.tlRadiusX, 0);
      expect(middle.trRadiusX, 0);
      expect(middle.blRadiusX, 0);
      expect(middle.brRadiusX, 0);
    });
  });

  group('HighlightPainter capsule branch', () {
    const metrics = CellMetrics(cellWidth: 8, cellHeight: 16, baseline: 12);
    const canvasColor = ui.Color(0xFF112233);
    const fill = ui.Color(0xFFEE0000); // opaque so probes are exact
    const width = 40;
    const height = 40;

    Future<ByteData> render(List<HighlightRange> highlights,
        {int rows = 1}) async {
      final state = TerminalPaintState(TerminalTheme.dark(), metrics)
        ..cols = 4
        ..rows = rows
        ..viewportOffset = 0
        ..highlights = highlights;

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawRect(
        const ui.Rect.fromLTWH(0, 0, width * 1.0, height * 1.0),
        ui.Paint()..color = canvasColor,
      );
      HighlightPainter(state).paint(canvas);
      final picture = recorder.endRecording();
      final image = await picture.toImage(width, height);
      final bytes = await image.toByteData();
      picture.dispose();
      image.dispose();
      return bytes!;
    }

    bool filled(ByteData bytes, {required int x, required int y}) {
      final offset = (y * width + x) * 4;
      final r = bytes.getUint8(offset);
      final g = bytes.getUint8(offset + 1);
      final b = bytes.getUint8(offset + 2);
      // Fully red only where the fill landed; treat any red-dominant blend
      // (anti-aliased edge) as filled.
      return r > 128 && g < 128 && b < 128;
    }

    // One capsule range over row 0, cols 1..3: cell rect LTRB(8,0,24,16),
    // capsule rect LTRB(5,2,27,18), radius 8, bulge center rows y in [2,18].
    const capsuleRange = HighlightRange(
      startRow: 0,
      startCol: 1,
      endRow: 0,
      endCol: 3,
      background: fill,
      capsule: true,
      capsuleStart: true,
      capsuleEnd: true,
    );

    test('capsule fills the padded rect: pad zone + descender outset', () async {
      final bytes = await render(const [capsuleRange]);
      // Center of the range.
      expect(filled(bytes, x: 16, y: 10), isTrue);
      // Horizontal PAD: 1px left of the cell edge (x=6 < cell left 8).
      expect(filled(bytes, x: 6, y: 10), isTrue);
      // TOP INSET: the slack band above the glyphs stays clear.
      expect(filled(bytes, x: 16, y: 0), isFalse);
      expect(filled(bytes, x: 16, y: 1), isFalse);
      // BOTTOM OUTSET: the wash extends past the cell bottom (y=17 > 16).
      expect(filled(bytes, x: 16, y: 17), isTrue);
    });

    test('rounded caps cut the corners; a continuation end stays square',
        () async {
      final capsule = await render(const [capsuleRange]);
      // Top-left corner pixel of the padded rect (5,2): outside the round cap.
      expect(filled(capsule, x: 5, y: 2), isFalse);
      // Same range as a WRAP CONTINUATION (no caps): square corners fill it.
      final square = await render(const [
        HighlightRange(
          startRow: 0,
          startCol: 1,
          endRow: 0,
          endCol: 3,
          background: fill,
          capsule: true,
        ),
      ]);
      expect(filled(square, x: 5, y: 2), isTrue);
    });

    test('multi-row capsule range: caps land on the true first/last rows only',
        () async {
      // Rows 0-1, start col 1, end col 3: row 0 runs to the grid edge
      // (col 4 -> x=32), row 1 starts at col 0.
      final bytes = await render(
        const [
          HighlightRange(
            startRow: 0,
            startCol: 1,
            endRow: 1,
            endCol: 3,
            background: fill,
            capsule: true,
            capsuleStart: true,
            capsuleEnd: true,
          ),
        ],
        rows: 2,
      );
      // Row 0 (padded rect LTRB(5,2,35,18)): LEFT cap rounded -> corner clear.
      expect(filled(bytes, x: 5, y: 2), isFalse);
      // Row 0 RIGHT end is a wrap cut -> square corner fills (34,2).
      expect(filled(bytes, x: 34, y: 2), isTrue);
      // Row 1 (padded rect LTRB(-3,18,27,34)): LEFT is a wrap cut -> square
      // corner fills at (0,18)..(0,33).
      expect(filled(bytes, x: 0, y: 33), isTrue);
      // Row 1 RIGHT cap rounded -> bottom-right corner clear.
      expect(filled(bytes, x: 26, y: 33), isFalse);
    });

    test('a plain (non-capsule) range keeps the exact cell-rect fill', () async {
      final bytes = await render(const [
        HighlightRange(
          startRow: 0,
          startCol: 1,
          endRow: 0,
          endCol: 3,
          background: fill,
        ),
      ]);
      // Exact cell bounds: no pad, no inset, no outset, square corners.
      expect(filled(bytes, x: 8, y: 0), isTrue);
      expect(filled(bytes, x: 23, y: 15), isTrue);
      expect(filled(bytes, x: 6, y: 8), isFalse);
      expect(filled(bytes, x: 16, y: 17), isFalse);
    });
  });
}
