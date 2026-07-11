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

  /// Translucent fill drawn behind the cells' glyphs (the highlight pass
  /// paints between the cell background and the glyph ink). When null the
  /// painter draws NO fill for this range (#767 Slice B opt-in).
  final Color? background;

  /// Underline color drawn under the cells. When null no underline is drawn.
  final Color? underline;

  /// Opaque value associated with this range, returned by hit-testing.
  ///
  /// The host uses this to recover what the cells represent (e.g. the URL
  /// or path string) when the user taps or long-presses a highlighted cell.
  final Object? payload;

  /// #1045: draw this range's background as a WASH CAPSULE instead of a bare
  /// cell rect: the fill is padded/inset per [highlightCapsuleRRect] (a little
  /// horizontal breathing room, the top slack band trimmed, a descender
  /// outset) so it frames the glyphs like the retired widget-layer bubble
  /// (#988/#1000) — but painted by [HighlightPainter] UNDER the glyph ink.
  final bool capsule;

  /// #1045: this range holds the anchor's TRUE START — its first row rounds
  /// the capsule's LEFT end. False on wrap-continuation ranges, whose left
  /// edge is cut square (the match flows through the wrap as ONE object).
  /// Only meaningful with [capsule].
  final bool capsuleStart;

  /// #1045: this range holds the anchor's TRUE END — its last row rounds the
  /// capsule's RIGHT end. See [capsuleStart].
  final bool capsuleEnd;

  const HighlightRange({
    required this.startRow,
    required this.startCol,
    required this.endRow,
    required this.endCol,
    this.background,
    this.underline,
    this.payload,
    this.capsule = false,
    this.capsuleStart = false,
    this.capsuleEnd = false,
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
      capsule: capsule,
      capsuleStart: capsuleStart,
      capsuleEnd: capsuleEnd,
    );
  }

  @override
  int get hashCode => Object.hash(startRow, startCol, endRow, endCol,
      background, underline, capsule, capsuleStart, capsuleEnd);

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
          payload == other.payload &&
          capsule == other.capsule &&
          capsuleStart == other.capsuleStart &&
          capsuleEnd == other.capsuleEnd;

  @override
  String toString() =>
      'HighlightRange($startRow:$startCol-$endRow:$endCol, '
      'payload: $payload)';
}

/// #1045 capsule wash geometry — the polish constants ported from the retired
/// widget-layer bubble so the behind-glyph wash reads IDENTICALLY.
///
/// HORIZONTAL padding on both sides so the capsule FRAMES the text with a
/// little breathing room instead of clipping the first/last glyph (#864 device
/// feedback).
const double kHighlightCapsulePadX = 3.0;

/// TOP inset: the cell rect spans the full typographic line height with its
/// empty slack band at the TOP (#864), so the wash trims most of that band —
/// but keeps a hair of it as breathing room above the glyph caps (#1000).
const double kHighlightCapsuleTopInset = 2.0;

/// BOTTOM outset (#1000): the glyph ink (descenders) runs close to the cell
/// rect's bottom, so the wash EXPANDS downward past it. The next row's top
/// slack band (see [kHighlightCapsuleTopInset]) absorbs the overhang, so
/// neighbors stay uncrowded.
const double kHighlightCapsuleBottomOutset = 2.0;

/// The rounded rect a capsule highlight row fills (#1045): [cellRect] (the
/// row's cell-range rect) padded/inset by the constants above, with capsule
/// radius (half the padded height) ONLY on the ends that are the anchor's
/// true start/end — a wrap-continuation edge is cut square so a wrapped match
/// reads as ONE object flowing through the wrap (#988). Pure; shared by the
/// fork's [HighlightPainter] and the app's Detection Lab preview so the
/// preview IS the runtime look.
RRect highlightCapsuleRRect(
  Rect cellRect, {
  required bool roundLeft,
  required bool roundRight,
}) {
  final rect = Rect.fromLTRB(
    cellRect.left - kHighlightCapsulePadX,
    cellRect.top + kHighlightCapsuleTopInset,
    cellRect.right + kHighlightCapsulePadX,
    cellRect.bottom + kHighlightCapsuleBottomOutset,
  );
  final radius = Radius.circular(rect.height / 2);
  return RRect.fromRectAndCorners(
    rect,
    topLeft: roundLeft ? radius : Radius.zero,
    bottomLeft: roundLeft ? radius : Radius.zero,
    topRight: roundRight ? radius : Radius.zero,
    bottomRight: roundRight ? radius : Radius.zero,
  );
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
