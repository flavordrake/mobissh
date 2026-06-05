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

  /// Whether this pattern is the regex-FREE OSC-8 HYPERLINK source (#767 Slice
  /// B) rather than a [regex]-driven text matcher. When true the scanner
  /// IGNORES [regex]/[trailingTrim]/[normalize] and instead walks the reader's
  /// cells, grouping MAXIMAL runs of adjacent cells that share the SAME non-null
  /// [CellReader.hyperlinkAt] URI into one [StructuredMatch] (payload = the URI).
  /// Because libghostty attaches the full OSC-8 URI to EVERY visible cell of the
  /// link — including soft/hard-wrapped continuation rows — a wrapped link spans
  /// its rows by construction, with NO regex, width, or wrap heuristic, and the
  /// payload is the EXACT full URI (so copy/open get the real link). An OSC-8
  /// match always WINS over an overlapping [regex] match (see [StructuredTextScanner.scan]).
  final bool isOsc8Source;

  const TextPattern({
    required this.id,
    required this.regex,
    this.style = const HighlightStyle(),
    this.normalize,
    this.trailingTrim = '',
    this.isOsc8Source = false,
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

  /// The built-in OSC-8 HYPERLINK source (#767 Slice B) — the PRIMARY, exact
  /// URL source.
  ///
  /// Unlike [TextPattern.url] (a regex over the visible glyph text), this reads
  /// the OSC-8 hyperlink URI libghostty attaches to each cell
  /// ([CellReader.hyperlinkAt]). The scanner groups maximal same-URI cell runs
  /// into one match whose payload is the EXACT full URI — so a wrapped link
  /// spans all its rows by construction and copy/open get the real link, with no
  /// regex / wrap / width heuristic. An OSC-8 match WINS over an overlapping
  /// regex URL match (the partial first-row `https://…` the regex would catch is
  /// suppressed on the hyperlinked cells), so a hyperlinked URL yields ONE exact
  /// anchor, not a partial regex bubble beside it. [style] supplies the highlight
  /// color (omitted by the app — the widget-layer bubble draws the affordance).
  factory TextPattern.osc8({String id = 'osc8', HighlightStyle style =
      const HighlightStyle()}) {
    return TextPattern(
      id: id,
      // Unused for an OSC-8 source — the scanner walks cells, not text. A
      // never-matching regex keeps [regex] non-null without false positives.
      regex: _kNeverMatch,
      style: style,
      isOsc8Source: true,
    );
  }
}

/// A regex that matches nothing — the placeholder [TextPattern.regex] for an
/// OSC-8 source, whose detection walks cells rather than running a regex.
final RegExp _kNeverMatch = RegExp(r'(?!x)x');

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

/// A persistent structured-text ANCHOR exposed to the widget layer (#767 Slice B).
///
/// The fork OWNS persistent cell-sequence anchoring (the [StructuredTextScanner]
/// re-anchors matches across scroll/wrap/resize/eviction by re-scanning the live
/// cells). Slice A painted those matches with one baked-in [HighlightPainter]
/// style. Slice B instead EXPOSES the matches as anchors so the widget layer can
/// inject ITS OWN per-pattern decorators (a URL bubble/chip, a future file-path
/// or commit-sha treatment) WITHOUT the fork picking a paint style — the
/// "unblock persistent understanding of where the cells are so decorators can be
/// injected without constant maintenance" requirement.
///
/// An anchor is a thin, immutable view over a single [StructuredMatch]: the
/// [patternId] that produced it, the opaque [payload] the cells represent (e.g.
/// the normalized URL), and the per-row absolute-coordinate [ranges] it occupies
/// (one per soft-wrapped row). The widget resolves a range to CURRENT viewport
/// pixel rects each frame via `TerminalController.anchorRects`, so a decorator
/// tracks scroll/wrap/resize/eviction with NO re-detection.
@immutable
final class StructuredAnchor {
  /// The [TextPattern.id] that produced this anchor's underlying match.
  final String patternId;

  /// The opaque value the anchored cells represent (e.g. the URL string).
  final Object payload;

  /// The per-row absolute-coordinate ranges this anchor occupies — one per row
  /// a soft-wrapped match spans (a single-row match has exactly one).
  final List<HighlightRange> ranges;

  const StructuredAnchor({
    required this.patternId,
    required this.payload,
    required this.ranges,
  });

  /// Builds an anchor from a detected [StructuredMatch].
  StructuredAnchor.fromMatch(StructuredMatch match)
    : patternId = match.patternId,
      payload = match.payload,
      ranges = match.ranges;

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

  /// The OSC-8 HYPERLINK URI attached to the cell at local ([row], [col]), or
  /// null when the cell carries no hyperlink (#767 Slice B).
  ///
  /// libghostty attaches the FULL OSC-8 URI to EVERY visible cell of a link —
  /// including soft/hard-wrapped continuation rows — so the OSC-8 source can
  /// group maximal same-URI runs into one match spanning all wrapped rows by
  /// construction. The real controller reads `GridRef.hyperlinkUri`; the test
  /// fake supplies a per-cell URI map. A blank/spacer-tail cell carries no
  /// hyperlink (null), so a non-link gap naturally breaks a run.
  String? hyperlinkAt(int row, int col);
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

    final regexPatterns = [for (final p in patterns) if (!p.isOsc8Source) p];
    final osc8Patterns = [for (final p in patterns) if (p.isOsc8Source) p];

    // OSC-8 FIRST: it is the PRIMARY, exact source and WINS over any overlapping
    // regex match. Collect the hyperlinked cells so an overlapping regex match
    // (the partial first-row `https://…` over the link's visible text) is
    // suppressed — yielding ONE exact anchor, not a partial bubble beside it.
    final matches = <StructuredMatch>[];
    final hyperlinkedCells = <int, Set<int>>{}; // absRow -> set of cols
    if (osc8Patterns.isNotEmpty) {
      for (final pattern in osc8Patterns) {
        for (final m in _scanOsc8(reader, rows, cols, pattern)) {
          matches.add(m);
          for (final range in m.ranges) {
            final set = hyperlinkedCells.putIfAbsent(range.startRow, () => {});
            for (var c = range.startCol; c < range.endCol; c++) {
              set.add(c);
            }
          }
        }
      }
    }

    if (regexPatterns.isEmpty) return matches;

    final lines = _assembleLines(reader, rows, cols);
    for (final line in lines) {
      final text = line.text;
      if (text.isEmpty) continue;
      for (final pattern in regexPatterns) {
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
          // De-dup: OSC-8 wins. Drop a regex match that overlaps ANY OSC-8
          // hyperlinked cell, so a hyperlinked URL (whose visible text is also
          // URL-shaped) yields only the exact OSC-8 anchor. A plain-text URL
          // (no OSC-8) is unaffected — the map is empty, so this never fires.
          if (hyperlinkedCells.isNotEmpty &&
              _overlapsHyperlink(line.glyphs, start, end, hyperlinkedCells)) {
            continue;
          }
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

  /// Whether the regex match spanning glyphs `[start, end)` overlaps any cell in
  /// [hyperlinkedCells] (absRow → covered cols). Used to SUPPRESS a regex match
  /// over OSC-8-hyperlinked cells so OSC-8 wins the de-dup (#767 Slice B).
  bool _overlapsHyperlink(
    List<_Glyph> glyphs,
    int start,
    int end,
    Map<int, Set<int>> hyperlinkedCells,
  ) {
    for (var i = start; i < end; i++) {
      final cols = hyperlinkedCells[glyphs[i].absRow];
      if (cols != null && cols.contains(glyphs[i].col)) return true;
    }
    return false;
  }

  /// Scan the reader's cells for OSC-8 hyperlink runs (#767 Slice B).
  ///
  /// Walks cells in READING ORDER (row 0..rows-1, col 0..cols-1) and groups each
  /// MAXIMAL contiguous run of cells sharing the SAME non-null
  /// [CellReader.hyperlinkAt] URI into one [StructuredMatch] (payload = the URI).
  /// "Contiguous" follows reading order: the next col on the same row, or col 0
  /// of the next row when the run reaches the row end — so a wrapped link (the
  /// same URI on row N's tail and row N+1's head) is ONE run spanning both rows
  /// by construction. A URI CHANGE or a non-link (null) cell ends the run, and a
  /// run is emitted as per-row [HighlightRange]s in absolute coordinates.
  List<StructuredMatch> _scanOsc8(
    CellReader reader,
    int rows,
    int cols,
    TextPattern pattern,
  ) {
    final base = reader.baseAbsRow;

    // Group ALL cells sharing the same hyperlink URI into ONE match — regardless
    // of intervening NON-link cells (trailing wrap padding) or row breaks.
    // libghostty attaches the SAME URI to every cell of a link, so same-URI cells
    // ARE the link even when an APP wraps it at its own content width (narrower
    // than the terminal) and PADS the rest of the row: that padding is a non-link
    // gap that must NOT split the link (the device bug — the link's first row
    // bubbled, the padded continuation did not). A flush-on-gap run breaks there;
    // grouping by URI does not. (No hyperlink-id is exposed by libghostty, so URI
    // is the grouping key; the rare case of the identical URI appearing as two
    // separate on-screen links merges into one anchor — harmless: both bubble and
    // copy the same exact URI.) `_rangesFor` turns the collected glyphs into one
    // range PER ROW, so a wrapped link spans its rows; intra-row padding is simply
    // absent from the glyph list and thus from the ranges.
    final byUri = <String, List<_Glyph>>{};
    final order = <String>[];
    for (var r = 0; r < rows; r++) {
      final absRow = base + r;
      for (var c = 0; c < cols; c++) {
        final uri = reader.hyperlinkAt(r, c);
        if (uri == null) continue;
        final glyphs = byUri.putIfAbsent(uri, () {
          order.add(uri);
          return <_Glyph>[];
        });
        glyphs.add(_Glyph(uri, absRow, c));
      }
    }

    final matches = <StructuredMatch>[];
    for (final uri in order) {
      final glyphs = byUri[uri]!;
      final ranges =
          _rangesFor(glyphs, 0, glyphs.length, pattern.style, uri);
      if (ranges.isNotEmpty) {
        matches.add(
          StructuredMatch(
            patternId: pattern.id,
            ranges: ranges,
            payload: uri,
          ),
        );
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
        if (r < rows - 1 && _continuesOnto(reader, r, cols)) {
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

  /// Whether logical content on local row [r] continues onto row [r]+1.
  ///
  /// Prefer libghostty's AUTHORITATIVE soft-wrap flag. When it is absent — as
  /// under tmux, which HARD-wraps at the pane width and never sets the flag —
  /// fall back to a wrap-width signal: row [r] fills the width (its last cell is
  /// non-blank) AND row [r]+1 begins with a BARE continuation. "Bare" excludes a
  /// blank/whitespace start, a bullet marker, and a fresh URL scheme — so a
  /// genuinely wrapped URL joins under tmux, while a COMPLETE URL that happens to
  /// fill the width is NOT merged into the next line's separate content (#764
  /// over-capture stays fixed even without the flag).
  bool _continuesOnto(CellReader reader, int r, int cols) {
    if (reader.rowWrap(r)) return true;
    if (reader.cellContent(r, cols - 1).isEmpty) return false; // not full width
    final next = r + 1;
    if (reader.cellContent(next, 0).isEmpty) return false; // blank/ws start
    return !_startsNewBlock(reader, next, cols);
  }

  /// Whether row [row] STARTS a new block rather than continuing the prior row:
  /// a leading bullet marker (a bullet glyph followed by a space — NOT a URL
  /// hyphen like the '-' in 'mobissh-native', which is followed by a non-space)
  /// or a fresh URL scheme ('http://', 'https://', 'www.'). Leading whitespace
  /// is already excluded by the col-0 blank check in [_continuesOnto].
  bool _startsNewBlock(CellReader reader, int row, int cols) {
    const bullets = {'-', '*', '+', '•', '·', '▪', '◦', '‣'};
    final c0 = reader.cellContent(row, 0);
    if (bullets.contains(c0) &&
        cols > 1 &&
        reader.cellContent(row, 1).isEmpty) {
      return true;
    }
    final head = _rowHead(reader, row, cols, 8).toLowerCase();
    return head.startsWith('http://') ||
        head.startsWith('https://') ||
        head.startsWith('www.');
  }

  /// The first [n] characters of row [row] (blank cells as spaces).
  String _rowHead(CellReader reader, int row, int cols, int n) {
    final lim = n < cols ? n : cols;
    final sb = StringBuffer();
    for (var c = 0; c < lim; c++) {
      final ch = reader.cellContent(row, c);
      sb.write(ch.isEmpty ? ' ' : ch);
    }
    return sb.toString();
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
      i++;
      // Extend while on the SAME row AND col-contiguous. A col GAP breaks the
      // range so the highlight never covers a non-match cell — needed for the
      // OSC-8 source, whose same-URI glyphs can skip cells (an app's wrap padding
      // between the link's rows, or a non-link cell between same-URI cells). The
      // regex path is unaffected: its glyphs come from the padded logical line, so
      // they are always col-contiguous within a row.
      while (i < end &&
          glyphs[i].absRow == rowAbs &&
          glyphs[i].col == lastCol + 1) {
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
