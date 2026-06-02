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
String fixupTerminalCopy(String input) {
  // 1. Normalize line endings.
  var s = input.replaceAll(_crlf, '\n');
  // 2. Trim trailing whitespace so soft-wrap detection sees the real boundary.
  s = s.replaceAll(_trailingWs, '\n');
  // 3. Preserve genuine paragraph breaks behind a control-char placeholder
  //    (U+0001, like the PWA) so the soft-wrap collapse leaves them alone;
  //    restored in step 6.
  final para = String.fromCharCode(1);
  s = s.replaceAll(_paragraphs, para);
  // 4. Token-aware soft-wrap collapse. Non-overlapping left-to-right (matches
  //    JS's global regex-replace), so a shared boundary word is consumed once.
  s = _collapseSoftWraps(s);
  // 5. Any remaining `\n` (wrap at doc start/end with no surrounding word)
  //    collapses to nothing.
  s = s.replaceAll(_remainingNl, '');
  // 6. Restore paragraph breaks.
  s = s.replaceAll(para, '\n');
  // 7. Trim outer whitespace (prompt indent / trailing newline).
  return s.trim();
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
