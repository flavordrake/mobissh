// #748 — URL highlight underline vertical geometry.
//
// The underline was drawn at the RAW CELL BOTTOM (`padding + (row+1)*cellHeight
// - 1.5`), which floats it in the descender/line-gap BELOW the URL glyphs —
// "drawn lower", and "worse further down the screen" because the gap repeats
// every row. The fix anchors the underline to each row's OWN glyph baseline
// (the cell bottom minus the below-baseline slack), a hair under the glyphs,
// with no per-row drift.
//
// `ghosttyUrlUnderlineY` is pure math (no Flutter binding / no font), so the
// geometry is gated here. The slack INPUT is measured on-device from the real
// font (`ghosttyMeasureBelowBaselineSlack`); the owner device-validates the
// visual.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

void main() {
  group('ghosttyUrlUnderlineY — glyph-bottom, not cell-bottom (#748)', () {
    const padding = 4.0;
    const cellHeight = 20.0;
    const slack = 5.0; // 5px of descender/line-gap below the baseline.
    const gap = 1.5;

    double rawCellBottom(int row) => padding + (row + 1) * cellHeight;
    double baseline(int row) => rawCellBottom(row) - slack;

    test(
      'underline hugs the glyph baseline (a hair below it), NOT the gap',
      () {
        for (final row in [0, 1, 5, 20, 46]) {
          final y = ghosttyUrlUnderlineY(
            padding: padding,
            cellHeight: cellHeight,
            belowBaselineSlack: slack,
            row: row,
          );
          // Sits just below the glyph baseline...
          expect(
            y,
            closeTo(baseline(row) + gap, 1e-9),
            reason: 'row $row should hug its baseline + a hair',
          );
          // ...and ABOVE the raw cell bottom (out of the line gap the old code
          // drew into).
          expect(
            y,
            lessThan(rawCellBottom(row)),
            reason: 'row $row must not sink to the raw cell bottom',
          );
        }
      },
    );

    test('no per-row DRIFT: the y delta between rows is exactly one cell', () {
      final y0 = ghosttyUrlUnderlineY(
        padding: padding,
        cellHeight: cellHeight,
        belowBaselineSlack: slack,
        row: 0,
      );
      final yHigh = ghosttyUrlUnderlineY(
        padding: padding,
        cellHeight: cellHeight,
        belowBaselineSlack: slack,
        row: 30,
      );
      // The offset INTO the cell (distance from each row's own cell top) is the
      // SAME for row 0 and a high row — the bug was this distance growing.
      final intoCell0 = y0 - (padding + 0 * cellHeight);
      final intoCellHigh = yHigh - (padding + 30 * cellHeight);
      expect(
        intoCellHigh,
        closeTo(intoCell0, 1e-9),
        reason: 'row 0 and a high row must hug their glyph identically',
      );
      // And the absolute delta is exactly the cell pitch (no accumulation).
      expect(yHigh - y0, closeTo(30 * cellHeight, 1e-9));
    });

    test(
      'zero slack → underline at (just past) the cell bottom, clamped in',
      () {
        final y = ghosttyUrlUnderlineY(
          padding: padding,
          cellHeight: cellHeight,
          belowBaselineSlack: 0.0,
          row: 3,
        );
        // No descender slack: baseline == cell bottom, +gap would overshoot, so
        // it clamps to the cell bottom (never below the cell).
        expect(y, closeTo(rawCellBottom(3), 1e-9));
      },
    );

    test('slack is clamped to the cell so the y stays inside the cell', () {
      final y = ghosttyUrlUnderlineY(
        padding: padding,
        cellHeight: cellHeight,
        belowBaselineSlack: cellHeight * 2, // absurd over-measurement
        row: 2,
      );
      final cellTop = padding + 2 * cellHeight;
      expect(
        y,
        greaterThanOrEqualTo(cellTop),
        reason: 'never above the cell top',
      );
      expect(
        y,
        lessThanOrEqualTo(cellTop + cellHeight),
        reason: 'never below the cell bottom',
      );
    });
  });
}
