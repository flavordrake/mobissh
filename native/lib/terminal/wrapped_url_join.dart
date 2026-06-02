// SPIKE (#570 Slice 2) — continuation-join heuristic for HARD-wrapped URLs.
//
// The spike's STEP 1 finding inverted the premise: a SOFT-wrapped URL (terminal
// display-wrapped, no \n in the byte stream) is ALREADY resolved by Slice 1's
// buffer reconstruction (url_hit_test.dart walks isWrapped rows) AND seen as one
// contiguous run by SessionStreamParser. The owner's real bug is the HARD case —
// the source/TUI emitted a LITERAL \n mid-URL — and there BOTH the buffer walk
// and the stream parser break at the newline.
//
// This module is the de-risk for the ONLY thing that actually moves the needle:
// rejoining a URL across a hard newline. It is a HEURISTIC, deliberately
// conservative, and PURE (no Flutter, no buffer). It is NOT wired into the
// production path — it exists to prove tractability and bound the effort.
//
// Heuristic: a hard wrap that splits a URL leaves a line ending in a URL-legal
// run with NO trailing whitespace, whose tail starts with a scheme OR is the
// continuation of a scheme on a prior line; the NEXT line begins (column 0) with
// a URL-legal, non-space character. Joining the two with no separator and
// re-running the URL matcher recovers the full URL. We only join when:
//   1. the left line's last char is URL-legal and not whitespace, AND
//   2. the left line contains a scheme `http(s)://` that has no whitespace after
//      it (the wrap fell inside the URL), AND
//   3. the right line's first char is URL-legal and not whitespace.
// Otherwise we do NOT join (a normal paragraph wrap must not glue two words).

import 'session_stream_parser.dart';

final RegExp _scheme = RegExp(r'https?://', caseSensitive: false);

bool _isUrlLegal(int c) {
  // Anything that is not whitespace and not an angle/quote delimiter — matches
  // the spirit of the default URL matcher's character class.
  if (c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d) return false;
  if (c == 0x3c || c == 0x3e) return false; // < >
  if (c == 0x22 || c == 0x27) return false; // " '
  return true;
}

/// Returns true when [left] and [right] look like the two halves of a single
/// URL that a HARD newline split, so they should be joined with no separator
/// before URL matching. Conservative — see file header.
bool shouldJoinHardWrap(String left, String right) {
  if (left.isEmpty || right.isEmpty) return false;
  if (!_isUrlLegal(left.codeUnitAt(left.length - 1))) return false;
  if (!_isUrlLegal(right.codeUnitAt(0))) return false;
  final m = _scheme.firstMatch(left);
  if (m == null) return false;
  // No whitespace AFTER the scheme on the left line → the wrap fell inside the
  // URL (the URL ran to the end of the line).
  final afterScheme = left.substring(m.end);
  if (afterScheme.contains(RegExp(r'\s'))) return false;
  return true;
}

/// Given a list of physical [lines] (as the source emitted them, split on hard
/// \n) reconstruct the logical text by gluing lines that pass
/// [shouldJoinHardWrap], then return every URL the default matcher finds in the
/// reconstructed logical text. Proves the heuristic recovers a hard-wrapped URL.
List<String> recoverHardWrappedUrls(List<String> lines) {
  if (lines.isEmpty) return const [];
  final buf = StringBuffer(lines.first);
  for (var i = 1; i < lines.length; i++) {
    final prevTail = buf.toString();
    if (shouldJoinHardWrap(prevTail, lines[i])) {
      buf.write(lines[i]); // glue, no separator
    } else {
      buf.write('\n');
      buf.write(lines[i]);
    }
  }
  final logical = buf.toString();
  return defaultUrlPattern.allMatches(logical).map((m) => m.group(0)!).toList();
}
