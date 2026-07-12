import 'dart:ui';

import '../../foundation/highlight_range.dart';
import '../paint_state.dart';
import 'terminal_painter.dart';

/// Paints the additive structured-text highlight layer.
///
/// Draws each [HighlightRange] from [TerminalPaintState.highlights] as a
/// translucent per-cell-row background fill (and an optional underline),
/// using the render box's real [CellMetrics] via
/// [CellMetrics.cellRangeRect] — so the highlight pixel-aligns to the glyph
/// cells with no separate geometry derivation.
///
/// Ranges store ABSOLUTE buffer rows. The painter re-reads
/// [TerminalPaintState.viewportOffset] each frame and maps each row to a
/// viewport row (`row - viewportOffset`), clipping to the visible grid. Rows
/// outside the viewport are skipped, so scroll, reflow, and resize track
/// without recomputing the ranges.
class HighlightPainter implements TerminalPainter {
  final TerminalPaintState _state;
  final Paint _fillPaint = Paint();
  final Paint _underlinePaint = Paint();

  HighlightPainter(this._state);

  @override
  void paint(Canvas canvas) {
    // #1067: the wash is NEVER hidden. It TRACKS its token LIVE every paint:
    // each range carries the anchor's ABSOLUTE buffer rows (the persistent #767
    // anchor set), and this painter maps `viewRow = absRow - viewportOffset`
    // against the SAME painted offset the glyphs use this frame (set by the
    // render box's frame sync). So the wash lands wherever the anchor CURRENTLY
    // is — through scroll AND content churn — with no baked/cached screen range
    // and no suppression gate. The pre-#1045 #988 live-resolution, repointed
    // behind the glyphs (the stack order background → highlight → text draws
    // this fill BENEATH the glyph ink, so the token stays full-contrast on top).
    final highlights = _state.highlights;
    // #1067: record the live-resolved viewport rows this paint for the test seam
    // (empty when nothing draws — reset every paint so it never goes stale).
    final washViewRows = <int>[];
    _state.debugWashViewRows = washViewRows;
    if (highlights.isEmpty) return;

    final rows = _state.rows;
    final cols = _state.cols;
    if (rows == 0 || cols == 0) return;

    final metrics = _state.metrics;
    final offset = _state.viewportOffset;
    final underlineTop = metrics.underlinePosition > 0
        ? metrics.underlinePosition
        : metrics.cellHeight - metrics.underlineThickness;

    for (final range in highlights) {
      final topRow = range.topRow;
      final bottomRow = range.bottomRow;

      for (var absRow = topRow; absRow <= bottomRow; absRow++) {
        final viewRow = absRow - offset;
        if (viewRow < 0 || viewRow >= rows) continue;
        washViewRows.add(viewRow);

        final startCol = absRow == topRow ? range.topCol : 0;
        final endCol = absRow == bottomRow ? range.bottomCol : cols;
        final clampedStart = startCol.clamp(0, cols);
        final clampedEnd = endCol.clamp(0, cols);
        if (clampedEnd <= clampedStart) continue;

        final rect = metrics.cellRangeRect(
          viewRow,
          clampedStart,
          clampedEnd,
          Offset.zero,
        );

        // #767 Slice B: only fill when the range OPTS IN with a background —
        // a null background draws nothing (the optional underline branch is
        // unchanged). This painter remains ONE optional built-in decorator,
        // not the mechanism every pattern is forced through. (The old comment
        // here claimed the pass painted above the text; the stack order —
        // TerminalPainterStack.paint: background → highlight → text — puts
        // this fill BENEATH the glyph ink, which is exactly why #1045 routes
        // the detection wash through it: glyphs stay full-contrast on top.)
        //
        // #1045: a capsule range draws the ported bubble-wash geometry
        // ([highlightCapsuleRRect]) — padded/inset, with rounded caps ONLY on
        // the anchor's true first/last rows (a wrap-continuation edge is cut
        // square, so a wrapped match reads as ONE object).
        final background = range.background;
        if (background != null) {
          _fillPaint.color = background;
          if (range.capsule) {
            canvas.drawRRect(
              highlightCapsuleRRect(
                rect,
                roundLeft: range.capsuleStart && absRow == topRow,
                roundRight: range.capsuleEnd && absRow == bottomRow,
              ),
              _fillPaint,
            );
          } else {
            canvas.drawRect(rect, _fillPaint);
          }
        }

        final underline = range.underline;
        if (underline != null) {
          _underlinePaint.color = underline;
          canvas.drawRect(
            Rect.fromLTWH(
              rect.left,
              rect.top + underlineTop,
              rect.width,
              metrics.underlineThickness,
            ),
            _underlinePaint,
          );
        }
      }
    }
  }
}
