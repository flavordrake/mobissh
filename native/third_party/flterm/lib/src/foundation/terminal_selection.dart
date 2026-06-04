import 'dart:math' as math;

import 'package:meta/meta.dart';

/// A selected range of terminal cells.
///
/// Stores the anchor point ([startRow], [startCol]) and the moving end
/// ([endRow], [endCol]) exactly as set by the gesture detector. The
/// anchor stays fixed while the moving end follows the pointer or
/// keyboard extension.
///
/// Use the normalized accessors ([topRow], [topCol], [bottomRow],
/// [bottomCol]) to get direction-independent bounds for painting or
/// text extraction. All column bounds follow the convention: top is
/// inclusive, bottom is exclusive.
///
/// Supports two modes:
/// - [TerminalSelectionMode.normal]: contiguous text that flows across
///   lines, like selecting text in a document.
/// - [TerminalSelectionMode.block]: rectangular column region, where
///   each row is independently clipped to the same column range.
///
/// ```dart
/// const selection = TerminalSelection(
///   startRow: 0,
///   startCol: 5,
///   endRow: 2,
///   endCol: 10,
/// );
/// if (selection.contains(1, 7)) print('Cell is selected');
/// ```
@immutable
final class TerminalSelection {
  /// Row of the anchor point (where the selection started).
  final int startRow;

  /// Column of the anchor point (where the selection started).
  final int startCol;

  /// Row of the moving end (where the pointer or keyboard cursor is).
  final int endRow;

  /// Column of the moving end (where the pointer or keyboard cursor is).
  final int endCol;

  /// Whether this is a normal (linear) or block (rectangular) selection.
  final TerminalSelectionMode mode;

  const TerminalSelection({
    required this.startRow,
    required this.startCol,
    required this.endRow,
    required this.endCol,
    this.mode = .normal,
  });

  /// Normalized bottom column (exclusive).
  ///
  /// In block mode, the larger of [startCol] and [endCol].
  /// In normal mode, the column of whichever endpoint is lower in the grid.
  int get bottomCol {
    if (mode == .block) return math.max(startCol, endCol);
    if (startRow < endRow) return endCol;
    if (startRow > endRow) return startCol;
    return math.max(startCol, endCol);
  }

  /// Normalized bottom row (inclusive). The larger of [startRow] and [endRow].
  int get bottomRow => startRow <= endRow ? endRow : startRow;

  @override
  int get hashCode => Object.hash(startRow, startCol, endRow, endCol, mode);

  /// Normalized top column (inclusive).
  ///
  /// In block mode, the smaller of [startCol] and [endCol].
  /// In normal mode, the column of whichever endpoint is higher in the grid.
  int get topCol {
    if (mode == .block) return math.min(startCol, endCol);
    if (startRow < endRow) return startCol;
    if (startRow > endRow) return endCol;
    return math.min(startCol, endCol);
  }

  /// Normalized top row (inclusive). The smaller of [startRow] and [endRow].
  int get topRow => startRow <= endRow ? startRow : endRow;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalSelection &&
          startRow == other.startRow &&
          startCol == other.startCol &&
          endRow == other.endRow &&
          endCol == other.endCol &&
          mode == other.mode;

  /// Returns true if the cell at ([row], [col]) falls within this selection.
  ///
  /// In normal mode, cells between the top and bottom bounds are fully
  /// selected; cells on the top and bottom rows are range-checked against
  /// their respective column bounds. In block mode, every row is checked
  /// against [topCol]..[bottomCol].
  bool contains(int row, int col) {
    if (row < topRow || row > bottomRow) return false;
    if (mode == .block) return col >= topCol && col < bottomCol;
    if (topRow == bottomRow) return col >= topCol && col < bottomCol;
    if (row == topRow) return col >= topCol;
    if (row == bottomRow) return col < bottomCol;
    return true;
  }

  /// Returns a new selection with the moving end shifted by [dRow] rows
  /// and [dCol] columns.
  ///
  /// Used by keyboard-driven selection extension (Shift+Arrow). The anchor
  /// point is preserved.
  ///
  /// In normal mode, horizontal overflow wraps to the next/previous row,
  /// matching how a cursor moves through text. In block mode, columns
  /// clamp independently without wrapping. Both modes clamp to within
  /// [totalCols] columns and [totalRows] rows.
  TerminalSelection moveEnd(
    int dRow,
    int dCol, {
    required int totalCols,
    required int totalRows,
  }) {
    var newRow = endRow + dRow;
    var newCol = endCol + dCol;

    if (mode == .block) {
      return TerminalSelection(
        startRow: startRow,
        startCol: startCol,
        endRow: newRow.clamp(0, totalRows - 1),
        endCol: newCol.clamp(0, totalCols),
        mode: mode,
      );
    }

    if (dRow == 0) {
      if (newCol > totalCols) {
        newRow++;
        newCol = 0;
      } else if (newCol < 0) {
        newRow--;
        newCol = totalCols;
      }
      if (newRow < 0) {
        newRow = 0;
        newCol = 0;
      } else if (newRow >= totalRows) {
        newRow = totalRows - 1;
        newCol = totalCols;
      }
    } else {
      newRow = newRow.clamp(0, totalRows - 1);
    }

    return TerminalSelection(
      startRow: startRow,
      startCol: startCol,
      endRow: newRow,
      endCol: newCol,
      mode: mode,
    );
  }

  /// Returns a new selection with both rows shifted by [delta].
  ///
  /// Used to keep the selection anchored to the same content when the
  /// viewport scrolls. Positive [delta] shifts the selection downward.
  /// Returns `this` when [delta] is zero.
  TerminalSelection scroll(int delta) {
    if (delta == 0) return this;
    return TerminalSelection(
      startRow: startRow + delta,
      startCol: startCol,
      endRow: endRow + delta,
      endCol: endCol,
      mode: mode,
    );
  }
}

/// How a selection region is shaped.
///
/// Determines the geometry used by [TerminalSelection.contains] and the
/// selection painter. Normal mode is the standard default; block mode is
/// typically activated by holding a modifier key during drag (configured
/// via [TerminalGestureSettings.blockSelectionModifier]).
enum TerminalSelectionMode {
  /// Contiguous text that flows across line breaks.
  ///
  /// The first row is selected from `topCol` to the end, middle rows are
  /// fully selected, and the last row is selected from the start to
  /// `bottomCol`. This is the standard selection mode in most terminals.
  normal,

  /// Rectangular column range independent of line content.
  ///
  /// Every row between `topRow` and `bottomRow` is selected from `topCol`
  /// to `bottomCol`, forming a visual rectangle. Activated by Alt+drag
  /// in most desktop terminals.
  block,
}
