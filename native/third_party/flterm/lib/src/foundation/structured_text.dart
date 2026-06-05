import 'dart:ui';

import 'package:meta/meta.dart';

import 'highlight_range.dart';

/// Structured-text detection over a terminal's OWN cells (#767 Slice A).
///
/// This is the in-fork, content-anchored replacement for the app-side URL
/// detector that used to regex-scan formatter text in VIEWPORT coordinates and
/// re-push `controller.highlights` on every controller notify (the root cause
/// of the #748/#750/#751/#764 drift). Here the scanner reads the terminal's
/// authoritative cells (content + soft-wrap + wide-char width) via a
/// [CellReader], walks LOGICAL lines joined by the AUTHORITATIVE per-row wrap
/// flag, runs each [TextPattern]'s regex over the joined text, and emits
/// [HighlightRange]s DIRECTLY in ABSOLUTE buffer-row coordinates — the same
/// frame the selection model and [HighlightPainter] maintain across scroll,
/// wrap, resize, and eviction.
///
/// The [CellReader] is the headless seam: the real controller reads
/// libghostty's `GridRef`/`RenderState` (native FFI, not unit-testable), while
/// tests supply a fake reader, exactly as the old `detectGhosttyUrls` took
/// `rows`/`rowWraps` lists. The scanner + match mapping are PURE Dart, so the
/// wrap/range/eviction edge cases are unit-testable without an emulator.

/// The paint style a [TextPattern] applies to each emitted [HighlightRange].
///
/// Carries the optional background fill and underline colors onto the ranges
/// the scanner produces, so a pattern's matches render in a consistent,
/// theme-supplied color. When [background] is null the highlight painter falls
/// back to [HighlightTheme.defaultBackground]; when [underline] is null no
/// underline is drawn.
@immutable
final class HighlightStyle {
  /// Translucent fill drawn behind matched cells (null → painter default).
  final Color? background;

  /// Underline color drawn under matched cells (null → no underline).
  final Color? underline;

  const HighlightStyle({this.background, this.underline});

  @override
  int get hashCode => Object.hash(background, underline);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HighlightStyle &&
          background == other.background &&
          underline == other.underline;
}

/// A detectable structured-text pattern (#767).
///
/// A pattern names a class of structured text (URL, path, …) with a [regex]
/// run over each logical line's joined cell text, a [style] applied to every
/// emitted range, and an optional [normalize] that maps a raw match string to
/// an opaque payload (e.g. prefixing a bare `www.` host with `https://`). When
/// [normalize] is null the raw matched string is the payload.
///
/// The built-in [TextPattern.url] reproduces the old app-side URL detector:
/// the same http/https/www regex, the same trailing-punctuation trim, and the
/// same `www.` → `https://` normalization, MOVED inward to run over cells.
@immutable
final class TextPattern {
  /// Stable identifier for this pattern, copied onto each [StructuredMatch].
  final String id;

  /// The regex run over each logical line's joined cell text.
  final RegExp regex;

  /// The paint style applied to every [HighlightRange] this pattern emits.
  final HighlightStyle style;

  /// Maps a raw match string to its payload, or null to use the raw string.
  final Object? Function(String raw)? normalize;

  /// Trailing characters trimmed off the END of a raw match before it is
  /// accepted, or empty to keep the raw match as-is. Mirrors the old
  /// detector's sentence-punctuation / unbalanced-closer trim.
  final String trailingTrim;

  const TextPattern({
    required this.id,
    required this.regex,
    this.style = const HighlightStyle(),
    this.normalize,
    this.trailingTrim = '',
  });

  /// The built-in URL pattern (#726/#764 moved in-fork, #767).
  ///
  /// Matches `http://` / `https://` absolute URLs and bare `www.` hosts,
  /// trims trailing sentence punctuation / unbalanced closers, and normalizes
  /// a bare `www.` host to `https://www…`. [style] supplies the highlight
  /// color (the session theme's selection color at the call site).
  factory TextPattern.url({String id = 'url', HighlightStyle style =
      const HighlightStyle()}) {
    return TextPattern(
      id: id,
      regex: _kUrlPattern,
      style: style,
      trailingTrim: _kUrlTrailingTrim,
      normalize: _normalizeUrl,
    );
  }
}

/// The URL regex (moved verbatim from the app's `ghostty_url_detector.dart`,
/// #767). Matches absolute http/https URLs and bare `www.` hosts; the
/// character class stops at whitespace and the few characters terminals/shells
/// never put mid-URL.
final RegExp _kUrlPattern = RegExp(
  r'(?:https?://|www\.)[^\s<>"'
  "'"
  r'`]+',
  caseSensitive: false,
);

/// Trailing characters trimmed off the END of a raw URL match (moved verbatim
/// from `ghostty_url_detector.dart`, #767).
const String _kUrlTrailingTrim = '.,;:!?)]}>\'"';

/// Normalise a raw URL match: prefix a bare `www.` host with `https://`
/// (moved verbatim from `ghostty_url_detector.dart`, #767).
String _normalizeUrl(String raw) {
  final lower = raw.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://')) return raw;
  return 'https://$raw';
}

/// A single detected structured-text match (#767).
///
/// [ranges] are the per-row [HighlightRange]s the match occupies, in ABSOLUTE
/// buffer-row coordinates — one range per row a soft-wrapped match spans (a
/// single-row match has exactly one). Each range carries [payload] so a later
/// hit-test recovers what the cells represent. [patternId] identifies which
/// [TextPattern] produced the match.
@immutable
final class StructuredMatch {
  /// The [TextPattern.id] that produced this match.
  final String patternId;

  /// The per-row absolute-coordinate ranges this match occupies.
  final List<HighlightRange> ranges;

  /// The opaque value the match represents (e.g. the normalized URL string).
  final Object payload;

  const StructuredMatch({
    required this.patternId,
    required this.ranges,
    required this.payload,
  });

  /// Returns true if the cell at ABSOLUTE ([row], [col]) falls in any range.
  bool contains(int row, int col) {
    for (final range in ranges) {
      if (range.contains(row, col)) return true;
    }
    return false;
  }
}

/// Read-only view of a terminal's cells for the [StructuredTextScanner].
///
/// The headless seam between the scanner (pure Dart, unit-testable) and
/// libghostty's native `GridRef`/`RenderState` (FFI). [rows] x [cols] is the
/// region to scan; [baseAbsRow] is the ABSOLUTE buffer row of local row 0, so
/// emitted ranges land in the absolute, top-anchored frame the painter and
/// selection model use. A scan re-reads [baseAbsRow] each pass, so when
/// scrollback EVICTS lines (every surviving line's absolute index shifts down)
/// a fresh scan emits the corrected rows by construction.
///
/// [cellContent] returns the cell's grapheme cluster as a string (empty for a
/// blank cell or a wide-character spacer tail). [rowWrap] is libghostty's
/// AUTHORITATIVE soft-wrap flag: true iff local [row] continues onto [row]+1.
abstract interface class CellReader {
  /// Number of local rows available to scan (e.g. viewport + bounded
  /// scrollback window).
  int get rows;

  /// Grid width in cells.
  int get cols;

  /// Absolute buffer row corresponding to local row 0.
  int get baseAbsRow;

  /// The grapheme content of the cell at local ([row], [col]); empty for a
  /// blank cell or a wide-character spacer tail.
  String cellContent(int row, int col);

  /// Whether local [row] is soft-wrapped onto local [row]+1 (authoritative).
  bool rowWrap(int row);
}

/// One character of a logical line, tagged with the absolute cell it came from.
class _Glyph {
  _Glyph(this.text, this.absRow, this.col);

  /// The cell's grapheme content (always non-empty — blanks become a space).
  final String text;

  /// Absolute buffer row of the cell.
  final int absRow;

  /// Column of the cell on its row.
  final int col;
}

/// A logical line assembled from one or more soft-wrapped rows (#767).
///
/// Unlike the old viewport-offset arithmetic (`offset ~/ cols`), each glyph
/// carries its EXACT origin cell, so mapping a regex match's character span
/// back to per-row absolute ranges never depends on padding/width guesses.
class _LogicalLine {
  _LogicalLine(this.glyphs);

  final List<_Glyph> glyphs;

  /// The joined text of all member cells, one char per cell.
  String get text => glyphs.map((g) => g.text).join();
}

/// Scans a terminal's cells for [TextPattern]s and emits [StructuredMatch]es
/// in ABSOLUTE buffer coordinates (#767).
///
/// Pure Dart over a [CellReader] — no FFI, no widget — so every wrap / range /
/// eviction edge case is unit-testable headless.
class StructuredTextScanner {
  const StructuredTextScanner();

  /// Scan [reader]'s cells for every pattern in [patterns].
  ///
  /// Walks logical lines (rows joined by [CellReader.rowWrap]), runs each
  /// pattern's [TextPattern.regex] over the joined text, trims the configured
  /// trailing characters, and maps each accepted match back to per-row
  /// [HighlightRange]s in absolute coordinates. Two adjacent matches yield two
  /// distinct [StructuredMatch]es (never merged); each terminates at the
  /// match's real last cell (no trailing-pad, no bleed into the next line).
  List<StructuredMatch> scan(CellReader reader, List<TextPattern> patterns) {
    if (patterns.isEmpty) return const [];
    final rows = reader.rows;
    final cols = reader.cols;
    if (rows <= 0 || cols <= 0) return const [];

    final lines = _assembleLines(reader, rows, cols);
    final matches = <StructuredMatch>[];
    for (final line in lines) {
      final text = line.text;
      if (text.isEmpty) continue;
      for (final pattern in patterns) {
        for (final m in pattern.regex.allMatches(text)) {
          var start = m.start;
          var end = m.end; // exclusive
          // Trim trailing sentence punctuation / unbalanced closers from the
          // END, mirroring the old detector.
          final trim = pattern.trailingTrim;
          while (end > start && trim.contains(text[end - 1])) {
            end--;
          }
          if (end <= start) continue;
          final raw = text.substring(start, end);
          final payload = pattern.normalize?.call(raw) ?? raw;
          final ranges = _rangesFor(
            line.glyphs,
            start,
            end,
            pattern.style,
            payload,
          );
          if (ranges.isEmpty) continue;
          matches.add(
            StructuredMatch(
              patternId: pattern.id,
              ranges: ranges,
              payload: payload,
            ),
          );
        }
      }
    }
    return matches;
  }

  /// Assemble local rows into logical lines, joining soft-wrapped rows by the
  /// AUTHORITATIVE [CellReader.rowWrap] flag (never guessed from width). A
  /// blank cell becomes a single space so column positions stay aligned and a
  /// URL never silently swallows a gap.
  List<_LogicalLine> _assembleLines(CellReader reader, int rows, int cols) {
    final base = reader.baseAbsRow;
    final lines = <_LogicalLine>[];
    var r = 0;
    while (r < rows) {
      final glyphs = <_Glyph>[];
      // Accumulate this row and every row it soft-wraps into.
      while (true) {
        final absRow = base + r;
        for (var c = 0; c < cols; c++) {
          final content = reader.cellContent(r, c);
          glyphs.add(_Glyph(content.isEmpty ? ' ' : content, absRow, c));
        }
        if (r < rows - 1 && reader.rowWrap(r)) {
          r++;
          continue;
        }
        break;
      }
      lines.add(_LogicalLine(glyphs));
      r++;
    }
    return lines;
  }

  /// Map a match's character span `[start, end)` in a logical line back to
  /// per-row [HighlightRange]s. Each contiguous run of glyphs on the SAME
  /// absolute row becomes one range; a wrapped match thus yields one range per
  /// row, each terminating at the match's real last cell on that row.
  List<HighlightRange> _rangesFor(
    List<_Glyph> glyphs,
    int start,
    int end,
    HighlightStyle style,
    Object payload,
  ) {
    final ranges = <HighlightRange>[];
    var i = start;
    while (i < end) {
      final rowAbs = glyphs[i].absRow;
      final startCol = glyphs[i].col;
      var lastCol = startCol;
      // Extend while still on the same absolute row and within the match.
      while (i < end && glyphs[i].absRow == rowAbs) {
        lastCol = glyphs[i].col;
        i++;
      }
      ranges.add(
        HighlightRange(
          startRow: rowAbs,
          startCol: startCol,
          endRow: rowAbs,
          endCol: lastCol + 1, // exclusive
          background: style.background,
          underline: style.underline,
          payload: payload,
        ),
      );
    }
    return ranges;
  }
}
