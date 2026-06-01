// Per-session rich-text stream parser (#570, Part A — parser core only).
//
// `SessionStreamParser` sits on a session's LOGICAL (decoded) text stream — it
// is fed chunks of terminal output, NOT per-rendered-line — and detects
// "rich" runs the UI can later make tappable:
//   - full URLs (a robust default matcher), and
//   - any number of caller-supplied token matchers (e.g. `/remote/path`,
//     `#hashid`).
//
// Why the LOGICAL stream and not rendered lines: a long URL the terminal
// SOFT-WRAPS across several display rows is a single contiguous run of
// characters in the logical stream, so it is detected as ONE match. Likewise a
// URL/token split across two fed chunks is coalesced. Matches carry the matched
// TEXT plus session-ABSOLUTE logical offsets (`start`/`end`) so a later UI
// layer (Part B) can map them onto rendered cells.
//
// Scalability: the parser keeps a bounded rolling buffer. After each feed it
// scans only the region up to the last "safe boundary" (the last whitespace /
// newline — no in-flight token can straddle it) and retains only the tail after
// that boundary for the next feed. This makes the work per feed O(new bytes +
// pending-tail), not O(total-history), so it stays cheap across large
// scrollback. The retained tail is additionally capped at [maxBufferChars]; a
// single unterminated token longer than that cap will not be matched (a token
// with no whitespace/newline for thousands of characters is not a real link).
//
// Coordination with #575 (SessionSignalDetector): that detector scans RAW BYTES
// for OSC-9 / BEL escape sequences (a control-byte domain). This parser scans
// DECODED logical text (a different domain). They are complementary, but #575's
// own note says the shared parser "can grow from this seam". The extension seam
// here is the pluggable [RichTextMatcher] list + the typed [StreamMatch] /
// [StreamMatchKind] taxonomy: an OSC/bell text-side consumer could be added as
// another matcher kind without changing the scan loop. That is NOT implemented
// here (it belongs to #575).
//
// This module is PURE (no Flutter, no I/O) and is exercised entirely by
// `test/terminal/session_stream_parser_test.dart` in the fast unit gate. Wiring
// it into the session output path (sessions.dart / session_host.dart) and the
// tap UI (terminal_screen.dart) is Part B — out of scope here. App-level config
// for the regex set (Part B / settings) would simply be passed as
// [extraMatchers] at construction, one parser per session.

/// The category of a detected run. URLs are first-class; everything a caller
/// configures is [custom]. The enum is the extension point for #575
/// (OSC/bell) and any future rich-text kind.
enum StreamMatchKind { url, custom }

/// A detected rich-text run in the logical stream.
class StreamMatch {
  const StreamMatch({
    required this.kind,
    required this.text,
    required this.start,
    required this.end,
  });

  /// What kind of run this is.
  final StreamMatchKind kind;

  /// The exact matched substring of the logical stream.
  final String text;

  /// Session-absolute start offset (inclusive) into the full logical stream the
  /// parser has been fed since construction.
  final int start;

  /// Session-absolute end offset (exclusive). `end - start == text.length`.
  final int end;

  @override
  String toString() => 'StreamMatch($kind, "$text", $start..$end)';
}

/// A pluggable matcher: a [RegExp] plus the [StreamMatchKind] its hits emit.
///
/// Matchers are applied to the same scanned region in order; the parser emits
/// every non-overlapping hit each matcher finds. Keeping matchers as plain data
/// is the seam that lets #575 add an OSC/bell matcher later without touching the
/// scan loop. (Named `RichTextMatcher`, not `StreamMatcher`, to avoid colliding
/// with `package:matcher`'s `StreamMatcher` in test files.)
class RichTextMatcher {
  const RichTextMatcher({required this.kind, required this.pattern});

  /// Kind emitted for hits of [pattern].
  final StreamMatchKind kind;

  /// The pattern to search for within the scanned region.
  final RegExp pattern;
}

/// Default robust-ish URL matcher: an http/https scheme followed by a run of
/// URL-legal characters, stopping before trailing sentence punctuation. It does
/// not try to be an RFC parser — it errs toward what a human would tap.
final RegExp _defaultUrlPattern = RegExp(
  // scheme://  then one-or-more URL chars, then a final URL char that is not
  // trailing punctuation (so "page." captures "page", not "page.").
  r'https?://[^\s<>"'
  "'"
  r']*[^\s<>"'
  "'"
  r'.,;:!?)\]}]',
  caseSensitive: false,
);

/// Consumes a session's logical text stream and emits [StreamMatch]es.
///
/// One instance per session by construction. Not thread-safe; feed from a single
/// sequence of calls (the session's output handler).
class SessionStreamParser {
  SessionStreamParser({
    required this.onMatch,
    List<RichTextMatcher>? extraMatchers,
    this.maxBufferChars = 8192,
  }) : _matchers = [
         RichTextMatcher(
           kind: StreamMatchKind.url,
           pattern: _defaultUrlPattern,
         ),
         ...?extraMatchers,
       ];

  /// Invoked once per detected match, in stream order.
  final void Function(StreamMatch match) onMatch;

  /// Upper bound on the retained rolling-buffer length. A pending (unterminated)
  /// token longer than this will not be matched. Default 8192 chars.
  final int maxBufferChars;

  final List<RichTextMatcher> _matchers;

  /// The rolling buffer: the not-yet-finalized tail of the logical stream.
  final StringBuffer _bufBuilder = StringBuffer();
  String _buf = '';

  /// Number of logical characters that have been finalized (scanned + dropped)
  /// before the current buffer. Absolute offset of `_buf[i]` is `_dropped + i`.
  int _dropped = 0;

  /// Current rolling-buffer length (for tests / introspection).
  int get bufferLength => _buf.length;

  /// Feed a chunk of LOGICAL (decoded) terminal output. Emits zero or more
  /// matches for any token that becomes complete with this chunk.
  void feed(String chunk) {
    if (chunk.isEmpty) return;
    _bufBuilder.write(chunk);
    _buf = _bufBuilder.toString();

    // Everything up to and including the last whitespace/newline is "safe":
    // no token can straddle a whitespace boundary, so any match wholly inside
    // that region is final. The tail after it may still be a partial token, so
    // we keep it for the next feed (coalescing).
    final safeEnd = _lastSafeBoundary(_buf);
    if (safeEnd > 0) {
      _scanRegion(0, safeEnd);
      _advance(safeEnd);
    }

    // Guard the retained tail against unbounded growth. If the tail (a single
    // run with no whitespace) exceeds the cap, drop its oldest characters.
    if (_buf.length > maxBufferChars) {
      _advance(_buf.length - maxBufferChars);
    }
  }

  /// Drop `count` characters from the front of the buffer, bumping the absolute
  /// offset base. Rebuilds the buffer compactly.
  void _advance(int count) {
    if (count <= 0) return;
    _dropped += count;
    _buf = _buf.substring(count);
    _bufBuilder
      ..clear()
      ..write(_buf);
  }

  /// Index just past the last whitespace character in [s], i.e. the end of the
  /// region in which every token is guaranteed complete. Returns 0 if [s] has
  /// no whitespace (the whole thing is one in-flight run).
  int _lastSafeBoundary(String s) {
    for (var i = s.length - 1; i >= 0; i--) {
      if (_isWhitespace(s.codeUnitAt(i))) return i + 1;
    }
    return 0;
  }

  bool _isWhitespace(int c) =>
      c == 0x20 || // space
      c == 0x09 || // tab
      c == 0x0a || // LF
      c == 0x0d || // CR
      c == 0x0c || // FF
      c == 0x0b; // VT

  /// Run every matcher over `_buf[start..end)` and emit hits with absolute
  /// offsets.
  void _scanRegion(int start, int end) {
    if (end <= start) return;
    final region = _buf.substring(start, end);
    final base = _dropped + start;
    for (final matcher in _matchers) {
      for (final m in matcher.pattern.allMatches(region)) {
        final matchText = m.group(0);
        if (matchText == null || matchText.isEmpty) continue;
        onMatch(
          StreamMatch(
            kind: matcher.kind,
            text: matchText,
            start: base + m.start,
            end: base + m.end,
          ),
        );
      }
    }
  }
}
