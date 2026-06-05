import 'dart:ui';

import 'cell_metrics.dart';
import 'highlight_range.dart';

/// Pure geometry resolver mapping a structured-text anchor's [HighlightRange]
/// (absolute buffer coords) to CURRENT viewport pixel rects (#767 Slice B).
///
/// This is the "expose where the cells are" seam that lets the widget layer
/// inject decorators without the fork baking in a paint style. It is PURE Dart
/// over [CellMetrics] + a viewport offset + a column count, so the "rects move
/// as the viewport scrolls", "one rect per visible row of a wrapped match", and
/// "empty when fully off-screen" properties are unit-testable headless, exactly
/// as the [HighlightPainter] computes them — but returned to the caller instead
/// of painted, so a decorator (URL bubble/chip, future gutter/path/sha) tracks
/// scroll/wrap/resize/eviction with no re-detection.
abstract final class AnchorGeometry {
  /// Resolve [range] to its visible viewport rects.
  ///
  /// [metrics] is the live cell size; [viewportOffset] is the absolute row of
  /// the top visible row (`scrollbar.offset`); [cols]/[viewportRows] bound the
  /// grid; [origin] offsets every rect into the grid's padded local space (the
  /// [TerminalView]'s padding). Emits one rect per row segment of [range] that
  /// is currently on-screen, hugging the matched cells; a fully off-screen range
  /// yields an EMPTY list. Returns empty when the grid is not measurable
  /// (`cellWidth`/`cellHeight` <= 0, or non-positive dimensions).
  static List<Rect> rectsFor(
    HighlightRange range, {
    required CellMetrics metrics,
    required int viewportOffset,
    required int cols,
    required int viewportRows,
    Offset origin = Offset.zero,
  }) {
    if (metrics.cellWidth <= 0 || metrics.cellHeight <= 0) return const [];
    if (cols <= 0 || viewportRows <= 0) return const [];
    final rects = <Rect>[];
    for (var absRow = range.topRow; absRow <= range.bottomRow; absRow++) {
      final viewRow = absRow - viewportOffset;
      if (viewRow < 0 || viewRow >= viewportRows) continue;
      final startCol = absRow == range.topRow ? range.topCol : 0;
      final endCol = absRow == range.bottomRow ? range.bottomCol : cols;
      final clampedStart = startCol.clamp(0, cols);
      final clampedEnd = endCol.clamp(0, cols);
      if (clampedEnd <= clampedStart) continue;
      rects.add(metrics.cellRangeRect(viewRow, clampedStart, clampedEnd, origin));
    }
    return rects;
  }

  /// The VIEWPORT row index a gutter decorator for [range] should mark, or null
  /// when [range] is fully off-screen (the top row of [range] still on-screen).
  static int? gutterRowFor(
    HighlightRange range, {
    required int viewportOffset,
    required int viewportRows,
  }) {
    if (viewportRows <= 0) return null;
    for (var absRow = range.topRow; absRow <= range.bottomRow; absRow++) {
      final viewRow = absRow - viewportOffset;
      if (viewRow < 0) continue;
      if (viewRow >= viewportRows) return null;
      return viewRow;
    }
    return null;
  }
}
