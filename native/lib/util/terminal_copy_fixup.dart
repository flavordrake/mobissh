// Terminal-copy fixup — Dart port of the PWA's `fixupTerminalCopy`
// (src/modules/ime-fixup.ts). Backs the compose "Fix" pill (#638).
//
// Round-trips text copied out of the terminal — where xterm soft-wraps long
// URLs / commands / API keys with a newline + indent (or a bare newline) — back
// into one clean, executable line. Deterministic; no semantic guessing.
//
// Heuristics (mirror the PWA exactly so behavior matches on both platforms):
//   - CR / CRLF normalize to `\n`.
//   - Trailing whitespace before a newline is trimmed.
//   - A newline (optionally followed by indent) between two words collapses:
//       * to NOTHING if either adjacent word contains URL/path punctuation
//         (a single token was wrapped mid-string), or
//       * to a single SPACE otherwise (wrapped prose).
//   - Genuine paragraph breaks (`\n{2,}`) are preserved as a single `\n`.
//   - Leading / trailing whitespace is trimmed.
//
// With the terminal width ([cols]) known the guesswork above is replaced by
// the char-wrap model a terminal actually follows: a row that FILLED every
// cell (`cols` chars, or `cols-1` when the copy trimmed a trailing space) was
// soft-wrapped and rejoins losslessly; any shorter — or wider — line ends in a
// newline the producer wrote, and that newline survives. Owner report
// 2026-09-07: two pasted commands were fused into `.rulessudo`, and `1965`
// split across rows as `19 65`. The PWA gets this distinction from xterm's
// `isWrapped`; native has no wrap flag on pasted text, so width is the
// discriminator.

/// URL/path punctuation that strongly signals "this run of non-whitespace is a
/// single token, not prose". Excludes `-` (too ambiguous — shell flags).
final RegExp _tokenPunct = RegExp(r'[/:?#&=%+._~]');

final RegExp _crlf = RegExp(r'\r\n?');
final RegExp _trailingWs = RegExp(r'[ \t]+\n');
final RegExp _paragraphs = RegExp(r'\n{2,}');
// A word, a newline + optional indent, then another word.
final RegExp _softWrap = RegExp(r'(\S+)\n[ \t]*(\S+)');
final RegExp _remainingNl = RegExp(r'\n[ \t]*');

/// Collapse common terminal-copy soft-wrap artifacts into one clean line while
/// preserving genuine paragraph breaks. Pure function — safe to unit test.
///
/// [cols] is the terminal width the text was wrapped at. Without it every
/// single newline is treated as a soft wrap (legacy heuristic).
String fixupTerminalCopy(String input, {int? cols}) {
  // 1. Normalize line endings.
  var s = input.replaceAll(_crlf, '\n');
  // 2. Trim trailing whitespace so soft-wrap detection sees the real boundary.
  s = s.replaceAll(_trailingWs, '\n');
  // 3. Preserve genuine breaks behind control-char placeholders (U+0001 for
  //    paragraphs, like the PWA; U+0002 for width-attested hard breaks) so the
  //    soft-wrap collapse leaves them alone; restored in step 6.
  final para = String.fromCharCode(1);
  final hard = String.fromCharCode(2);
  if (cols != null && cols > 0) s = _rejoinRows(s, cols, hard) ?? s;
  s = s.replaceAll(_paragraphs, para);
  // 4. Token-aware soft-wrap collapse. Non-overlapping left-to-right (matches
  //    JS's global regex-replace), so a shared boundary word is consumed once.
  s = _collapseSoftWraps(s);
  // 5. Any remaining `\n` (wrap at doc start/end with no surrounding word)
  //    collapses to nothing.
  s = s.replaceAll(_remainingNl, '');
  // 6. Restore paragraph and hard breaks.
  s = s.replaceAll(para, '\n').replaceAll(hard, '\n');
  // 7. Trim outer whitespace (prompt indent / trailing newline).
  return s.trim();
}

/// Char-wrap model, applied when the terminal width is known. For each
/// newline between two non-blank lines:
///   - previous line is exactly [cols] long → the row was full and the wrap
///     fell mid-stream: rejoin with NOTHING, next line verbatim (its leading
///     whitespace is real content — `1965` / ` 0017`).
///   - previous line is [cols]-1 long → full row whose last cell was a space
///     the copy trimmed: rejoin with that one space.
///   - anything else could not have been a wrapped row → [hard] break.
/// Newlines next to blank lines are left for the paragraph rule.
///
/// Returns null when no line reaches the terminal edge at all: the text was
/// not wrapped by THIS terminal (a narrower foreign wrap, an indented URL out
/// of a PDF/mail), so the width says nothing and the legacy heuristic runs.
/// Trade-off, deliberate: two short commands pasted together still fuse under
/// Fix; the owner-reported fusions (a line wider than the terminal, or a
/// partial row after full ones) are the attested cases and are preserved.
String? _rejoinRows(String s, int cols, String hard) {
  final lines = s.split('\n');
  if (!lines.any((l) => l.length >= cols - 1)) return null;
  final buf = StringBuffer(lines.first);
  for (var i = 1; i < lines.length; i++) {
    final prev = lines[i - 1];
    final next = lines[i];
    if (prev.isEmpty || next.isEmpty) {
      buf.write('\n');
    } else if (prev.length == cols) {
      // full row: nothing to write between them
    } else if (prev.length == cols - 1) {
      buf.write(' ');
    } else {
      buf.write(hard);
    }
    buf.write(next);
  }
  return buf.toString();
}

/// Equivalent of JS `String.replace(/(\S+)\n[ \t]*(\S+)/g, fn)`: non-overlapping
/// left-to-right replacement. After a match, scanning resumes at the end of the
/// replacement, so a shared boundary word is not re-consumed.
String _collapseSoftWraps(String s) {
  final buf = StringBuffer();
  var last = 0;
  for (final m in _softWrap.allMatches(s)) {
    if (m.start < last) continue; // overlaps a prior consumed match
    buf.write(s.substring(last, m.start));
    final prev = m.group(1)!;
    final next = m.group(2)!;
    final isToken = _tokenPunct.hasMatch(prev) || _tokenPunct.hasMatch(next);
    buf.write(prev);
    buf.write(isToken ? '' : ' ');
    buf.write(next);
    last = m.end;
  }
  buf.write(s.substring(last));
  return buf.toString();
}
