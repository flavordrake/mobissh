// Terminal URL hit-testing (#570): map a long-press to a buffer cell and, if
// the cell lands on a detected URL, return that URL plus the buffer-cell range
// it occupies (for the transient highlight overlay).
//
// THE TWO COORDINATE SYSTEMS (the core difficulty):
//   * SessionStreamParser tracks session-ABSOLUTE offsets in the decoded LOGICAL
//     stream.
//   * A tap yields a (row, col) in xterm's 2D buffer — a circular scrollback
//     that TRIMS old lines and REFLOWS on resize. Those drift relative to the
//     parser's absolute offsets, so reconciling them is fragile.
//
// The answer: don't reconcile. At tap time, reconstruct the full
// soft-wrap-coalesced LOGICAL line straight from the live buffer at the tapped
// row, then run the SAME URL regex (urlMatchAt, from session_stream_parser) over
// that line and test column containment. Robust to trimming + reflow because it
// reads the buffer as it is right now.
//
// Cell mapping itself is NOT reimplemented: xterm's RenderTerminal exposes a
// PUBLIC `getCellOffset(Offset) -> CellOffset(x: col, y: absoluteBufferRow)`
// that already accounts for scroll offset + padding. The UI feeds it the
// gesture's local offset and uses the returned cell directly.

import 'package:xterm/xterm.dart';

import 'session_stream_parser.dart';

/// Result of a successful URL hit-test: the matched URL plus where in the
/// reconstructed logical line it sits. The buffer row the tap landed on and the
/// logical-line column range let the UI translate the match back into per-row
/// buffer cells for the highlight overlay (a soft-wrapped URL spans rows).
class UrlHit {
  const UrlHit({
    required this.url,
    required this.row,
    required this.col,
    required this.logicalStart,
    required this.logicalEnd,
    required this.logicalLineStartRow,
    required this.lineWidth,
  });

  /// The matched URL substring (same detection as the stream parser).
  final String url;

  /// Absolute buffer row the tap landed on.
  final int row;

  /// Column within the LOGICAL (soft-wrap-coalesced) line the tap landed on.
  final int col;

  /// Start column (inclusive) of the URL within the logical line.
  final int logicalStart;

  /// End column (exclusive) of the URL within the logical line.
  final int logicalEnd;

  /// The absolute buffer row at which the logical line begins (its first,
  /// non-wrapped row). Combined with [lineWidth] this maps a logical-line column
  /// back to a (row, col) buffer cell: row = startRow + col ~/ width, etc.
  final int logicalLineStartRow;

  /// The terminal's view width (columns per rendered row) at hit time, used to
  /// translate a logical-line column into a (row, col) buffer cell.
  final int lineWidth;

  @override
  String toString() =>
      'UrlHit($url @ row=$row col=$col [$logicalStart,$logicalEnd))';
}

/// Reconstruct the full LOGICAL line that buffer row [row] belongs to, by
/// walking back over `isWrapped` continuations to the logical start and forward
/// while subsequent rows are wrapped continuations. Returns the concatenated
/// text, the column OFFSET that [row]'s start sits at within that logical line,
/// and the absolute buffer row the logical line begins at.
///
/// xterm marks a row `isWrapped == true` when it is the CONTINUATION of the row
/// ABOVE it (a soft wrap). So the logical line is: the first ancestor row that
/// is NOT wrapped, then every following row while it IS wrapped.
({String line, int rowStartCol, int startRow}) reconstructLogicalLine(
  Buffer buffer,
  int row,
) {
  final lines = buffer.lines;
  final total = lines.length;
  if (row < 0 || row >= total) {
    return (line: '', rowStartCol: 0, startRow: row);
  }

  // Walk back to the logical start: the first row at-or-above [row] whose
  // `isWrapped` is false. Row 0 is always a logical start.
  var start = row;
  while (start > 0 && lines[start].isWrapped) {
    start--;
  }

  // Walk forward to the logical end: include rows while the NEXT row is a
  // wrapped continuation.
  var end = start;
  while (end + 1 < total && lines[end + 1].isWrapped) {
    end++;
  }

  // Concatenate. Track where [row]'s text begins within the logical line so the
  // caller can offset a per-row column into a logical-line column.
  final builder = StringBuffer();
  var rowStartCol = 0;
  for (var i = start; i <= end; i++) {
    if (i == row) {
      rowStartCol = builder.length;
    }
    builder.write(lines[i].getText());
  }
  return (line: builder.toString(), rowStartCol: rowStartCol, startRow: start);
}

/// Hit-test entry point. Given the [terminal] and a [cell] returned by
/// `RenderTerminal.getCellOffset`, reconstruct the logical line at the cell's
/// row and return the URL the cell lands on (or null).
///
/// [perRowCol] is the column WITHIN the tapped buffer row (xterm's
/// `CellOffset.x`). We add the row's start offset within the reconstructed
/// logical line so the column indexes the coalesced string correctly.
UrlHit? hitTestUrl(Terminal terminal, CellOffset cell) {
  final recon = reconstructLogicalLine(terminal.buffer, cell.y);
  if (recon.line.isEmpty) return null;
  final logicalCol = recon.rowStartCol + cell.x;
  final url = urlMatchAt(recon.line, logicalCol);
  if (url == null) return null;

  // Recover the URL's [start, end) within the logical line so the overlay can
  // highlight the exact run (urlMatchAt only returns the matched text).
  var start = 0;
  var endEx = recon.line.length;
  for (final m in defaultUrlPattern.allMatches(recon.line)) {
    if (logicalCol >= m.start && logicalCol < m.end) {
      start = m.start;
      endEx = m.end;
      break;
    }
  }

  return UrlHit(
    url: url,
    row: cell.y,
    col: logicalCol,
    logicalStart: start,
    logicalEnd: endEx,
    logicalLineStartRow: recon.startRow,
    lineWidth: terminal.viewWidth,
  );
}
