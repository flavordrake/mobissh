// Ghostty URL smart-select — Slice 1 PURE matcher (#726).
//
// Detects http/https/www URLs in the VISIBLE terminal viewport and maps each
// to a viewport cell RANGE so the [GhosttyTerminalView] can:
//   - HIGHLIGHT each URL (an overlay drawn over the cell range), and
//   - resolve a TAP cell to a URL (single-tap copies it).
//
// This file is PURE Dart (no FFI / no flterm widget) so it is unit-testable
// headless — the flterm buffer-READ that feeds it is the only native part, and
// the view passes that text + grid metrics in.
//
// How the view reads the visible buffer text (the flterm API found, #726):
// flterm 0.0.3's public `TerminalController` exposes `createFormatter(format:
// plain, unwrap: false).format()`, which returns the ACTIVE SCREEN (the visible
// viewport — NOT scrollback) as plain text, one VISIBLE ROW per `\n`-separated
// line. (The internal `terminal`/`GridRef`/`lineBoundaryAt` row API and the
// libghostty `Selection`/`PointTag` types are NOT exported, so per-row grid
// reads aren't available publicly — the row-joined formatter output is.) The
// view splits that on `\n` to get the per-row strings this matcher consumes.
//
// SOFT-WRAP joining (like the PWA #570): a terminal soft-wraps a long logical
// line across several viewport rows with NO break character. `unwrap: false`
// keeps those as separate rows, so this matcher RE-JOINS them: a row whose
// trimmed-right content fills the FULL grid width ([cols]) is treated as
// soft-wrapped into the next row, and a URL spanning the wrap is detected on the
// joined logical line, then mapped back to a multi-row cell range. This is the
// standard width heuristic (flterm's own `rowWrap` flag is internal/unexported).
//
// OUT OF SCOPE for Slice 1 (do NOT add here): long-press options menu / Open
// (Slice 2), file paths (Slice 3), scrollback URLs. Visible buffer + URLs only.

/// A detected URL and the VIEWPORT cell range it occupies (#726).
///
/// Coordinates are 0-based viewport cells: [startRow]/[endRow] are visible-row
/// indices (0 == top visible row), [startCol] is the first cell of the URL and
/// [endCol] is EXCLUSIVE (one past the last cell) on [endRow]. A URL that fits
/// on one row has `startRow == endRow`; a URL across a soft-wrap spans rows.
class GhosttyUrlMatch {
  const GhosttyUrlMatch({
    required this.url,
    required this.startCol,
    required this.startRow,
    required this.endCol,
    required this.endRow,
  });

  /// The matched URL text (already normalised — a bare `www.` match is prefixed
  /// with `https://`).
  final String url;

  /// First cell column (0-based, inclusive) on [startRow].
  final int startCol;

  /// First visible row (0-based).
  final int startRow;

  /// One-past-the-last cell column (0-based, EXCLUSIVE) on [endRow].
  final int endCol;

  /// Last visible row (0-based).
  final int endRow;

  @override
  bool operator ==(Object other) =>
      other is GhosttyUrlMatch &&
      other.url == url &&
      other.startCol == startCol &&
      other.startRow == startRow &&
      other.endCol == endCol &&
      other.endRow == endRow;

  @override
  int get hashCode => Object.hash(url, startCol, startRow, endCol, endRow);

  @override
  String toString() =>
      'GhosttyUrlMatch($url @ ($startCol,$startRow)->($endCol,$endRow))';
}

/// The URL pattern (#726). Matches `http://` / `https://` absolute URLs and
/// bare `www.` hosts. Trailing sentence punctuation (`.,;:!?` and a closing
/// bracket/quote) is excluded from the match so a URL at the end of a sentence
/// doesn't swallow the period — mirroring the PWA detector.
///
/// Deliberately conservative for Slice 1: no `ftp:`/`mailto:`/file paths
/// (Slice 3), no IDN/unicode hosts. The character class stops at whitespace and
/// the few characters terminals/shells never put MID-url.
final RegExp _kUrlPattern = RegExp(
  r'(?:https?://|www\.)[^\s<>"'
  "'"
  r'`]+',
  caseSensitive: false,
);

/// Trailing characters trimmed off the END of a raw match (sentence
/// punctuation / unbalanced closers) so `(see https://x.com).` → `https://x.com`.
const String _kTrailingTrim = '.,;:!?)]}>\'"';

/// A logical line assembled from one or more soft-wrapped viewport rows, with
/// enough geometry to map a character offset in the joined text back to a
/// (col, row) viewport cell. Internal to [detectGhosttyUrls].
class _LogicalLine {
  _LogicalLine(this.text, this.rows, this.cols);

  /// The joined text of all rows in this logical line (rows concatenated with
  /// NO separator, exactly as a soft-wrap reads).
  final String text;

  /// The 0-based viewport row indices this logical line spans, in order.
  final List<int> rows;

  /// The grid width (cells per row) used to map a flat offset to (col, row).
  final int cols;

  /// Map a 0-based character [offset] in [text] to a (col, row) viewport cell.
  ///
  /// Each row holds up to [cols] characters; offsets past the assembled text
  /// clamp to the last row's end. Used to resolve a URL's start/end offset to
  /// the cell where the highlight begins/ends.
  (int col, int row) cellAt(int offset) {
    if (cols <= 0 || rows.isEmpty) return (0, rows.isEmpty ? 0 : rows.first);
    final clamped = offset < 0 ? 0 : offset;
    final rowIndex = clamped ~/ cols;
    final col = clamped % cols;
    if (rowIndex >= rows.length) {
      // Past the last assembled row — clamp to the end of the final row.
      return (cols, rows.last);
    }
    return (col, rows[rowIndex]);
  }
}

/// Whether viewport [row] (its right-trimmed text [content]) soft-wraps into the
/// next row — i.e. its content fills the FULL grid width [cols] with no trailing
/// blank (the standard width heuristic, since flterm's `rowWrap` flag isn't
/// exported). A row shorter than [cols] ended naturally (a real line break).
bool _rowSoftWraps(String content, int cols) =>
    cols > 0 && content.length >= cols;

/// Assemble visible [rows] (one string per viewport row, top-first) into
/// logical lines, joining soft-wrapped rows by the [cols]-width heuristic.
///
/// Each row is right-padded to [cols] when joined so a character offset in the
/// joined text maps cleanly to (offset % cols, rows[offset ~/ cols]) — a URL
/// that wraps mid-row then continues on the next row keeps contiguous cells.
List<_LogicalLine> _logicalLines(List<String> rows, int cols) {
  final lines = <_LogicalLine>[];
  var i = 0;
  while (i < rows.length) {
    final memberRows = <int>[i];
    final buffer = StringBuffer();
    // A soft-wrapped row contributes its FULL [cols] cells (right-padded) so the
    // next row's text continues at a clean row boundary in the flat offset map.
    var current = rows[i];
    while (_rowSoftWraps(_trimRight(current), cols) && i + 1 < rows.length) {
      buffer.write(_padRight(current, cols));
      i++;
      current = rows[i];
      memberRows.add(i);
    }
    buffer.write(current);
    lines.add(_LogicalLine(buffer.toString(), memberRows, cols));
    i++;
  }
  return lines;
}

String _trimRight(String s) {
  var end = s.length;
  while (end > 0 && (s.codeUnitAt(end - 1) == 0x20)) {
    end--;
  }
  return s.substring(0, end);
}

String _padRight(String s, int width) {
  if (s.length >= width) return s.substring(0, width);
  return s + (' ' * (width - s.length));
}

/// Normalise a raw match: prefix a bare `www.` host with `https://`.
String _normalizeUrl(String raw) {
  final lower = raw.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://')) return raw;
  return 'https://$raw';
}

/// Detect http/https/www URLs in the VISIBLE viewport [rows] (#726).
///
/// [rows] is one string per visible viewport row (top-first), as read from
/// `controller.createFormatter(format: plain, unwrap: false).format()` split on
/// `\n`. [cols] is the grid width, used to (a) re-join soft-wrapped rows into a
/// logical line and (b) map a URL's character offset back to viewport cells.
///
/// Returns one [GhosttyUrlMatch] per URL with its 0-based viewport cell range
/// ([endCol] exclusive). A URL spanning a soft-wrap yields a multi-row range.
/// Pure (no FFI / no widget) → unit-testable headless.
List<GhosttyUrlMatch> detectGhosttyUrls(
  List<String> rows, {
  required int cols,
}) {
  if (cols <= 0 || rows.isEmpty) return const [];
  final matches = <GhosttyUrlMatch>[];
  for (final line in _logicalLines(rows, cols)) {
    for (final m in _kUrlPattern.allMatches(line.text)) {
      var raw = m.group(0)!;
      // Trim trailing sentence punctuation / unbalanced closers from the END.
      while (raw.isNotEmpty && _kTrailingTrim.contains(raw[raw.length - 1])) {
        raw = raw.substring(0, raw.length - 1);
      }
      if (raw.isEmpty) continue;
      final startOffset = m.start;
      final endOffset = m.start + raw.length; // exclusive in joined text
      final (startCol, startRow) = line.cellAt(startOffset);
      final (endCol, endRow) = line.cellAt(endOffset);
      matches.add(
        GhosttyUrlMatch(
          url: _normalizeUrl(raw),
          startCol: startCol,
          startRow: startRow,
          endCol: endCol,
          endRow: endRow,
        ),
      );
    }
  }
  return matches;
}

/// Whether the 0-based viewport cell ([col], [row]) falls inside [match]'s
/// range (#726). Used by the tap handler to resolve a tap to a URL.
///
/// The range reads left-to-right, top-to-bottom: a cell is inside iff it is at
/// or after the start cell AND strictly before the (exclusive) end cell, walking
/// rows in order. A single-row match is a simple `[startCol, endCol)` test; a
/// multi-row match includes the start row's tail, every full interior row, and
/// the end row's head.
bool ghosttyCellInUrl(
  GhosttyUrlMatch match, {
  required int col,
  required int row,
}) {
  if (row < match.startRow || row > match.endRow) return false;
  if (match.startRow == match.endRow) {
    return col >= match.startCol && col < match.endCol;
  }
  if (row == match.startRow) return col >= match.startCol;
  if (row == match.endRow) return col < match.endCol;
  return true; // an interior fully-covered row
}

/// Find the URL the 0-based viewport cell ([col], [row]) lands in, or null
/// (#726). The first match containing the cell wins (URLs never overlap).
GhosttyUrlMatch? ghosttyUrlAtCell(
  List<GhosttyUrlMatch> matches, {
  required int col,
  required int row,
}) {
  for (final m in matches) {
    if (ghosttyCellInUrl(m, col: col, row: row)) return m;
  }
  return null;
}
