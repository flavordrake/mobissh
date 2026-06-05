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
// the forked `TerminalController` exposes `createFormatter(format: plain,
// unwrap: false).format()`, which returns the ACTIVE SCREEN (the visible
// viewport — NOT scrollback) as plain text, one VISIBLE ROW per `\n`-separated
// line. The view splits that on `\n` to get the per-row strings this matcher
// consumes.
//
// SOFT-WRAP joining — AUTHORITATIVE (#764, replacing the #751 width heuristic):
// a terminal soft-wraps a long logical line across several viewport rows with NO
// break character. `unwrap: false` keeps those as separate rows, so this matcher
// RE-JOINS them — but it no longer GUESSES the wrap from row width. The fork now
// surfaces libghostty's own per-row soft-wrap flag (`rowGetWrap`) as
// `controller.viewportRowWraps`: element `[r]` is true iff visible row `r` is
// soft-wrapped onto row `r + 1`. The view passes that list in as [rowWraps], and
// this matcher joins row `r` into `r + 1` IFF `rowWraps[r]` is true. A URL
// spanning a wrap is detected on the joined logical line, then mapped back to a
// multi-row cell range that terminates at the URL's real end — so two adjacent
// URLs yield two separate ranges and a full-width-but-NOT-wrapped row (the case
// the old width heuristic mis-joined) is never merged.
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

/// Assemble visible [rows] (one string per viewport row, top-first) into
/// logical lines, joining soft-wrapped rows by the AUTHORITATIVE [rowWraps]
/// flags (#764): row `i` continues onto row `i + 1` IFF `rowWraps[i]` is true.
///
/// Each joined row contributes its FULL [cols] cells (right-padded to [cols]) so
/// a character offset in the joined text maps cleanly to
/// `(offset % cols, rows[offset ~/ cols])` — a URL that wraps mid-row then
/// continues on the next row keeps contiguous cells. The FINAL row of a logical
/// line is NOT padded (its real length terminates the line), so a URL ending on
/// that row maps to its true end column. A missing/short [rowWraps] entry is
/// treated as `false` (no wrap) — never guessed from width.
List<_LogicalLine> _logicalLines(
  List<String> rows,
  int cols,
  List<bool> rowWraps,
) {
  bool wrapsInto(int i) => i >= 0 && i < rowWraps.length && rowWraps[i];

  final lines = <_LogicalLine>[];
  var i = 0;
  while (i < rows.length) {
    final memberRows = <int>[i];
    final buffer = StringBuffer();
    // While the AUTHORITATIVE flag says this row soft-wraps into the next, pad
    // it to a full [cols] row and continue assembling the same logical line.
    while (wrapsInto(i) && i + 1 < rows.length) {
      buffer.write(_padRight(rows[i], cols));
      i++;
      memberRows.add(i);
    }
    // The terminating row contributes its real text (NOT padded) so the line
    // ends exactly where the on-screen content ends.
    buffer.write(rows[i]);
    lines.add(_LogicalLine(buffer.toString(), memberRows, cols));
    i++;
  }
  return lines;
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

/// Detect http/https/www URLs in the VISIBLE viewport [rows] (#726, #764).
///
/// [rows] is one string per visible viewport row (top-first), as read from
/// `controller.createFormatter(format: plain, unwrap: false).format()` split on
/// `\n`. [cols] is the grid width, used to map a URL's character offset back to
/// viewport cells.
///
/// [rowWraps] is the AUTHORITATIVE per-row soft-wrap flag list from
/// `controller.viewportRowWraps` (libghostty's `rowGetWrap`): `rowWraps[r]` is
/// true iff visible row `r` is soft-wrapped onto row `r + 1`. Soft-wrapped rows
/// are joined into one logical line by THIS flag — never guessed from row width
/// (the #751/#764 over/under-capture bug). When omitted (e.g. a caller that has
/// no wrap info), every row is treated as a self-contained line (no joining).
///
/// Returns one [GhosttyUrlMatch] per URL with its 0-based viewport cell range
/// ([endCol] exclusive). A URL spanning a soft-wrap yields a multi-row range
/// terminating at the URL's real end; two adjacent URLs yield two ranges.
/// Pure (no FFI / no widget) → unit-testable headless.
List<GhosttyUrlMatch> detectGhosttyUrls(
  List<String> rows, {
  required int cols,
  List<bool> rowWraps = const [],
}) {
  if (cols <= 0 || rows.isEmpty) return const [];
  final matches = <GhosttyUrlMatch>[];
  for (final line in _logicalLines(rows, cols, rowWraps)) {
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
