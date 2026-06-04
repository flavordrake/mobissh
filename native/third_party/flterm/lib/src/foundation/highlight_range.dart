import 'dart:ui';

import 'package:meta/meta.dart';

/// A range of terminal cells to draw a structured-text highlight over.
///
/// Additive overlay primitive layered on top of the rendered grid (used for
/// URL / path / regex highlights that the host application detects). It does
/// not affect terminal state, selection, or text — only the highlight paint
/// pass reads it.
///
/// Rows are ABSOLUTE buffer rows, top-anchored in the same coordinate frame
/// as [TerminalSelection] (row 0 is the oldest scrollback row). The painter
/// re-reads the viewport offset each frame, so scroll, reflow, and resize
/// track for free without recomputing the ranges. Columns follow the
/// terminal convention: [startCol] is inclusive, [endCol] is exclusive.
///
/// Each range carries its own optional [background] fill and [underline]
/// colors, plus an opaque [payload] the host can hit-test back to (via
/// `TerminalController.highlightAt`) — e.g. the URL string behind the cells.
///
/// ```dart
/// const range = HighlightRange(
///   startRow: 4,
///   startCol: 6,
///   endRow: 4,
///   endCol: 30,
///   payload: 'https://example.com',
/// );
/// if (range.contains(4, 10)) print('cell is highlighted');
/// ```
@immutable
final class HighlightRange {
  /// Absolute buffer row where the range starts (inclusive).
  final int startRow;

  /// Column where the range starts on [startRow] (inclusive).
  final int startCol;

  /// Absolute buffer row where the range ends (inclusive).
  final int endRow;

  /// Column where the range ends on [endRow] (exclusive).
  final int endCol;

  /// Translucent fill drawn behind the cells. When null the highlight
  /// painter falls back to [HighlightTheme.defaultBackground].
  final Color? background;

  /// Underline color drawn under the cells. When null no underline is drawn.
  final Color? underline;

  /// Opaque value associated with this range, returned by hit-testing.
  ///
  /// The host uses this to recover what the cells represent (e.g. the URL
  /// or path string) when the user taps or long-presses a highlighted cell.
  final Object? payload;

  const HighlightRange({
    required this.startRow,
    required this.startCol,
    required this.endRow,
    required this.endCol,
    this.background,
    this.underline,
    this.payload,
  });

  /// Normalized top row (inclusive). The smaller of [startRow] and [endRow].
  int get topRow => startRow <= endRow ? startRow : endRow;

  /// Normalized bottom row (inclusive). The larger of [startRow] and [endRow].
  int get bottomRow => startRow <= endRow ? endRow : startRow;

  /// Normalized top column (inclusive) on [topRow].
  int get topCol => startRow <= endRow ? startCol : endCol;

  /// Normalized bottom column (exclusive) on [bottomRow].
  int get bottomCol => startRow <= endRow ? endCol : startCol;

  /// Returns true if the cell at ([row], [col]) falls within this range.
  ///
  /// Cells between the top and bottom rows are fully covered; cells on the
  /// top and bottom rows are range-checked against their respective column
  /// bounds, matching how contiguous text flows across line breaks.
  bool contains(int row, int col) {
    if (row < topRow || row > bottomRow) return false;
    if (topRow == bottomRow) return col >= topCol && col < bottomCol;
    if (row == topRow) return col >= topCol;
    if (row == bottomRow) return col < bottomCol;
    return true;
  }

  /// Returns a copy with both rows shifted by [delta].
  ///
  /// Used to keep the range anchored to the same content when the viewport
  /// scrolls. Returns `this` when [delta] is zero.
  HighlightRange scroll(int delta) {
    if (delta == 0) return this;
    return HighlightRange(
      startRow: startRow + delta,
      startCol: startCol,
      endRow: endRow + delta,
      endCol: endCol,
      background: background,
      underline: underline,
      payload: payload,
    );
  }

  @override
  int get hashCode =>
      Object.hash(startRow, startCol, endRow, endCol, background, underline);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HighlightRange &&
          startRow == other.startRow &&
          startCol == other.startCol &&
          endRow == other.endRow &&
          endCol == other.endCol &&
          background == other.background &&
          underline == other.underline &&
          payload == other.payload;

  @override
  String toString() =>
      'HighlightRange($startRow:$startCol-$endRow:$endCol, '
      'payload: $payload)';
}

/// Default colors for the structured-text highlight paint pass.
///
/// A [HighlightRange] carries its own optional [HighlightRange.background] and
/// [HighlightRange.underline] colors. When a range leaves [HighlightRange.background]
/// null, the highlight painter falls back to [defaultBackground] so a plain
/// `HighlightRange(...)` still renders a visible translucent fill.
@immutable
final class HighlightTheme {
  /// Translucent fill used when a range omits its own background color.
  static const Color defaultBackground = Color(0x335B9BD5);

  const HighlightTheme._();
}
