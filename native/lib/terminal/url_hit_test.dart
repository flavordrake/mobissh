// SPIKE (#570/#631): terminal URL hit-testing — buffer-side core.
//
// DO NOT MERGE AS-IS. This is the de-risking spike for "copy & navigate URLs"
// in the native app. It proves the risky unknown: that a tap/long-press on the
// xterm.dart 4.0.0 TerminalView can be mapped to a buffer cell and that cell
// matched against a detected-URL range — without reimplementing xterm's layout
// math and without breaking scroll or mouse-reporting.
//
// THE TWO COORDINATE SYSTEMS (the core difficulty):
//   * SessionStreamParser (#570 Part A) tracks session-ABSOLUTE offsets in the
//     decoded LOGICAL stream.
//   * A tap yields a (row, col) in xterm's 2D buffer — a circular scrollback
//     that TRIMS old lines and REFLOWS on resize. Those drift relative to the
//     parser's absolute offsets, so reconciling them is fragile.
//
// THE SPIKE'S ANSWER: don't reconcile. At tap time, reconstruct the full
// soft-wrap-coalesced LOGICAL line straight from the live buffer at the tapped
// row, then run the SAME URL regex (urlMatchAt, from session_stream_parser) over
// that line and test column containment. Robust to trimming + reflow because it
// reads the buffer as it is right now.
//
// Cell mapping itself is NOT reimplemented: xterm's RenderTerminal exposes a
// PUBLIC `getCellOffset(Offset) -> CellOffset(x: col, y: absoluteBufferRow)`
// that already accounts for scroll offset + padding. We feed it the gesture's
// local offset and use the returned cell directly.

import 'package:xterm/xterm.dart';

import 'session_stream_parser.dart';

/// Result of a successful URL hit-test: the matched URL plus the buffer cell it
/// was found at (kept for a future highlight overlay — Slice 1).
class UrlHit {
  const UrlHit({required this.url, required this.row, required this.col});

  /// The matched URL substring (same detection as the stream parser).
  final String url;

  /// Absolute buffer row the tap landed on.
  final int row;

  /// Column within the LOGICAL (soft-wrap-coalesced) line the tap landed on.
  final int col;

  @override
  String toString() => 'UrlHit($url @ row=$row col=$col)';
}

/// Reconstruct the full LOGICAL line that buffer row [row] belongs to, by
/// walking back over `isWrapped` continuations to the logical start and forward
/// while subsequent rows are wrapped continuations. Returns the concatenated
/// text and the column OFFSET that [row]'s start sits at within that logical
/// line (so a per-row column can be translated into a logical-line column).
///
/// xterm marks a row `isWrapped == true` when it is the CONTINUATION of the row
/// ABOVE it (a soft wrap). So the logical line is: the first ancestor row that
/// is NOT wrapped, then every following row while it IS wrapped.
({String line, int rowStartCol}) reconstructLogicalLine(
  Buffer buffer,
  int row,
) {
  final lines = buffer.lines;
  final total = lines.length;
  if (row < 0 || row >= total) {
    return (line: '', rowStartCol: 0);
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
  return (line: builder.toString(), rowStartCol: rowStartCol);
}

/// The spike's hit-test entry point. Given the [terminal] and a [cell] returned
/// by `RenderTerminal.getCellOffset`, reconstruct the logical line at the cell's
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
  return UrlHit(url: url, row: cell.y, col: logicalCol);
}
