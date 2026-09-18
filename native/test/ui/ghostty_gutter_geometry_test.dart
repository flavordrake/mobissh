// #1155 (Slice 2 of #1153) — ONE gutter geometry value drives every consumer
// (R20). `GhosttyGutterGeometry({side, mode, stripWidth})` is the single
// source the grid math (`ghosttyGridForBox`), the touch→cell map
// (`ghosttyCellForPosition`), the TerminalView padding, the wash rects and both
// gutter layers read. Drift between any two = bug, so these PURE tests pin:
//   - the padding / reserved width per side×mode (R18 overlay = today,
//     R19 column reserves the 28dp strip on the gutter side; D2 the strip is
//     28dp in BOTH modes),
//   - the PTY column count: identical for overlay-left vs overlay-right, and
//     exactly `floor(innerW/cellW) - floor((innerW-28)/cellW)` fewer in column
//     mode on EITHER side; rows never change (R19),
//   - the touch→cell map agrees with where the wash layer places cell (0,0)
//     for all four combinations (R20).
// No FFI / no widget → fast gate.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/state/detection_providers.dart';
import 'package:mobissh/ui/ghostty_gutter_layer.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

const _overlayRight = GhosttyGutterGeometry(
  side: GutterSide.right,
  mode: GutterMode.overlay,
);
const _overlayLeft = GhosttyGutterGeometry(
  side: GutterSide.left,
  mode: GutterMode.overlay,
);
const _columnRight = GhosttyGutterGeometry(
  side: GutterSide.right,
  mode: GutterMode.column,
);
const _columnLeft = GhosttyGutterGeometry(
  side: GutterSide.left,
  mode: GutterMode.column,
);

const _all = <String, GhosttyGutterGeometry>{
  'overlay/right': _overlayRight,
  'overlay/left': _overlayLeft,
  'column/right': _columnRight,
  'column/left': _columnLeft,
};

/// Where the wash layer places the top-left visible cell (col 0, row 0) for
/// [g]: the flterm TerminalView padding PLUS the geometry's reserved inset on
/// the gutter side. The wash rect derivation and the touch→cell map must agree
/// on this origin (R20).
Rect _washRectForCell(GhosttyGutterGeometry g, int col, int row,
    {required double cellW, required double cellH}) {
  final left = kGhosttyTerminalPadding + g.terminalPadding.left + col * cellW;
  final top = kGhosttyTerminalPadding + g.terminalPadding.top + row * cellH;
  return Rect.fromLTWH(left, top, cellW, cellH);
}

void main() {
  group('#1155 GhosttyGutterGeometry (R18/R19/R20, D2)', () {
    test('D2: the strip is 28dp and the default stripWidth is that constant',
        () {
      expect(kGutterStripWidth, 28.0);
      for (final e in _all.entries) {
        expect(e.value.stripWidth, kGutterStripWidth, reason: e.key);
      }
    });

    test('R18 overlay: NO reserved width and ZERO extra padding on both sides',
        () {
      for (final g in [_overlayRight, _overlayLeft]) {
        expect(g.reservedWidth, 0.0, reason: '${g.side} overlay reserves 0');
        expect(g.terminalPadding, EdgeInsets.zero,
            reason: '${g.side} overlay adds no TerminalView padding');
      }
    });

    test('R19 column/left: reserves the strip on the LEFT only', () {
      expect(_columnLeft.reservedWidth, kGutterStripWidth);
      expect(
        _columnLeft.terminalPadding,
        const EdgeInsets.only(left: kGutterStripWidth),
      );
      expect(_columnLeft.terminalPadding.right, 0.0);
      expect(_columnLeft.terminalPadding.top, 0.0);
      expect(_columnLeft.terminalPadding.bottom, 0.0);
    });

    test('R19 column/right: reserves the strip on the RIGHT only', () {
      expect(_columnRight.reservedWidth, kGutterStripWidth);
      expect(
        _columnRight.terminalPadding,
        const EdgeInsets.only(right: kGutterStripWidth),
      );
      expect(_columnRight.terminalPadding.left, 0.0);
    });

    test('a custom stripWidth flows into padding + reserved width (column)',
        () {
      const g = GhosttyGutterGeometry(
        side: GutterSide.left,
        mode: GutterMode.column,
        stripWidth: 40,
      );
      expect(g.reservedWidth, 40.0);
      expect(g.terminalPadding, const EdgeInsets.only(left: 40));
      // Overlay ignores it for geometry purposes (nothing is reserved).
      const o = GhosttyGutterGeometry(
        side: GutterSide.left,
        mode: GutterMode.overlay,
        stripWidth: 40,
      );
      expect(o.reservedWidth, 0.0);
      expect(o.terminalPadding, EdgeInsets.zero);
    });

    test('isLeft mirrors the side regardless of mode (R15)', () {
      expect(_overlayLeft.isLeft, isTrue);
      expect(_columnLeft.isLeft, isTrue);
      expect(_overlayRight.isLeft, isFalse);
      expect(_columnRight.isLeft, isFalse);
    });

    test('defaults is right/overlay and EQUALS fromSettings(DetectionSettings())'
        ' — zero visual change by default (R7)', () {
      expect(GhosttyGutterGeometry.defaults.side, GutterSide.right);
      expect(GhosttyGutterGeometry.defaults.mode, GutterMode.overlay);
      expect(GhosttyGutterGeometry.defaults.stripWidth, kGutterStripWidth);
      expect(
        GhosttyGutterGeometry.fromSettings(const DetectionSettings()),
        GhosttyGutterGeometry.defaults,
      );
      expect(GhosttyGutterGeometry.defaults, _overlayRight);
    });

    test('fromSettings maps gutterSide + gutterMode from DetectionSettings',
        () {
      expect(
        GhosttyGutterGeometry.fromSettings(
          const DetectionSettings(
            gutterSide: GutterSide.left,
            gutterMode: GutterMode.column,
          ),
        ),
        _columnLeft,
      );
      expect(
        GhosttyGutterGeometry.fromSettings(
          const DetectionSettings(gutterSide: GutterSide.left),
        ),
        _overlayLeft,
      );
      expect(
        GhosttyGutterGeometry.fromSettings(
          const DetectionSettings(gutterMode: GutterMode.column),
        ),
        _columnRight,
      );
      // Intensity / enabled never touch the geometry.
      expect(
        GhosttyGutterGeometry.fromSettings(
          const DetectionSettings(
            enabled: false,
            intensity: DetectionIntensity.high,
          ),
        ),
        GhosttyGutterGeometry.defaults,
      );
    });
  });

  group('#1155 ghosttyGridForBox honours the geometry (R19)', () {
    // Box: inner 360 x 340 (padding 4 each side), cell 9 x 17.
    //   overlay: floor(360/9) = 40 cols, floor(340/17) = 20 rows.
    //   column:  floor((360-28)/9) = floor(36.9) = 36 cols → delta 4 (>= 1).
    const cellW = 9.0;
    const cellH = 17.0;
    const boxW = 360.0 + 2 * kGhosttyTerminalPadding;
    const boxH = 340.0 + 2 * kGhosttyTerminalPadding;
    const innerW = 360.0;

    (int, int) grid(GhosttyGutterGeometry g) => ghosttyGridForBox(
          boxWidth: boxW,
          boxHeight: boxH,
          cellWidth: cellW,
          cellHeight: cellH,
          geometry: g,
        );

    test('the default geometry is TODAY\'s math (no geometry arg == defaults)',
        () {
      final today = ghosttyGridForBox(
        boxWidth: boxW,
        boxHeight: boxH,
        cellWidth: cellW,
        cellHeight: cellH,
      );
      expect(today, (40, 20));
      expect(grid(GhosttyGutterGeometry.defaults), today);
      expect(grid(_overlayRight), today);
    });

    test('R18: overlay-left has the SAME cols as overlay-right (nothing '
        'reserved on either side)', () {
      expect(grid(_overlayLeft), grid(_overlayRight));
      expect(grid(_overlayLeft).$1, 40);
    });

    test('R19: column mode drops exactly floor(innerW/cellW) - '
        'floor((innerW-28)/cellW) cols on EITHER side', () {
      final expectedDelta =
          (innerW / cellW).floor() - ((innerW - kGutterStripWidth) / cellW).floor();
      expect(expectedDelta, greaterThanOrEqualTo(1),
          reason: 'the fixture box must be able to discriminate');
      final (overlayCols, _) = grid(_overlayRight);
      for (final g in [_columnLeft, _columnRight]) {
        final (cols, _) = grid(g);
        expect(cols, overlayCols - expectedDelta,
            reason: '${g.side} column mode reserves the strip in the grid');
        expect(cols, 36);
      }
      // reservedWidth is the exact width subtracted from innerW.
      expect(
        grid(_columnLeft).$1,
        ((innerW - _columnLeft.reservedWidth) / cellW).floor(),
      );
    });

    test('R19: rows are UNCHANGED by side or mode (the strip is vertical)', () {
      for (final e in _all.entries) {
        expect(grid(e.value).$2, 20, reason: e.key);
      }
    });

    test('column-mode delta holds for several real cell widths', () {
      for (final cw in [7.3, 8.6, 9.1, 11.0]) {
        final overlay = ghosttyGridForBox(
          boxWidth: boxW,
          boxHeight: boxH,
          cellWidth: cw,
          cellHeight: cellH,
          geometry: _overlayLeft,
        ).$1;
        final column = ghosttyGridForBox(
          boxWidth: boxW,
          boxHeight: boxH,
          cellWidth: cw,
          cellHeight: cellH,
          geometry: _columnLeft,
        ).$1;
        expect(overlay, (innerW / cw).floor(), reason: 'cw=$cw overlay');
        expect(column, ((innerW - kGutterStripWidth) / cw).floor(),
            reason: 'cw=$cw column');
      }
    });

    test('a box narrower than one cell after reserving still yields >= 1 col',
        () {
      final (cols, rows) = ghosttyGridForBox(
        boxWidth: kGutterStripWidth + 2 * kGhosttyTerminalPadding + 2,
        boxHeight: boxH,
        cellWidth: cellW,
        cellHeight: cellH,
        geometry: _columnRight,
      );
      expect(cols, 1);
      expect(rows, 20);
    });
  });

  group('#1155 R20: touch→cell agrees with the wash rect for cell (0,0) in all '
      'four side×mode combinations', () {
    const cellW = 9.0;
    const cellH = 17.0;
    const boxW = 360.0 + 2 * kGhosttyTerminalPadding;
    const boxH = 340.0 + 2 * kGhosttyTerminalPadding;

    (int, int) cellAt(GhosttyGutterGeometry g, Offset p) {
      final (cols, rows) = ghosttyGridForBox(
        boxWidth: boxW,
        boxHeight: boxH,
        cellWidth: cellW,
        cellHeight: cellH,
        geometry: g,
      );
      return ghosttyCellForPosition(
        dx: p.dx,
        dy: p.dy,
        cellWidth: cellW,
        cellHeight: cellH,
        cols: cols,
        rows: rows,
        geometry: g,
      );
    }

    for (final e in _all.entries) {
      final g = e.value;
      test('${e.key}: the centre of the wash rect for (0,0) maps to cell (1,1)',
          () {
        final r00 = _washRectForCell(g, 0, 0, cellW: cellW, cellH: cellH);
        expect(cellAt(g, r00.center), (1, 1));
      });

      test('${e.key}: the wash rect for (1,0) maps to (2,1) — the x offset is '
          'pinned, not merely clamped', () {
        final r10 = _washRectForCell(g, 1, 0, cellW: cellW, cellH: cellH);
        expect(cellAt(g, r10.center), (2, 1));
        // And one px LEFT of that rect is still col 1.
        expect(cellAt(g, Offset(r10.left - 1, r10.center.dy)), (1, 1));
      });

      test('${e.key}: the wash rect for (2,3) maps to (3,4)', () {
        final r = _washRectForCell(g, 2, 3, cellW: cellW, cellH: cellH);
        expect(cellAt(g, r.center), (3, 4));
      });
    }

    test('column/left: a touch INSIDE the reserved strip clamps to col 1 '
        '(never 0 or negative)', () {
      final inStrip = Offset(kGhosttyTerminalPadding + kGutterStripWidth / 2,
          kGhosttyTerminalPadding + cellH / 2);
      expect(cellAt(_columnLeft, inStrip).$1, 1);
      expect(cellAt(_columnLeft, const Offset(0, 0)), (1, 1));
    });

    test('column/right: a touch inside the reserved strip clamps to the '
        'REDUCED last col', () {
      final (cols, _) = ghosttyGridForBox(
        boxWidth: boxW,
        boxHeight: boxH,
        cellWidth: cellW,
        cellHeight: cellH,
        geometry: _columnRight,
      );
      expect(cols, 36);
      final inStrip = Offset(boxW - kGhosttyTerminalPadding - 1,
          kGhosttyTerminalPadding + cellH / 2);
      expect(cellAt(_columnRight, inStrip).$1, cols);
    });

    test('overlay-left vs overlay-right: identical mapping for the same touch '
        '(R17 the wash layer is side-agnostic)', () {
      for (final p in [
        const Offset(20, 30),
        const Offset(200, 150),
        const Offset(350, 300),
      ]) {
        expect(cellAt(_overlayLeft, p), cellAt(_overlayRight, p),
            reason: 'touch $p');
      }
    });
  });
}
