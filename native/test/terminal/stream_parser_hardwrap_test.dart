// SPIKE diagnostic (#570 Slice 2) — what SessionStreamParser does with a HARD
// (literal-\n) wrapped URL, and whether a continuation-join heuristic recovers
// it. This is the actual bug shape (owner build 0.1.2+4): the source/TUI
// inserted a newline mid-URL before the terminal saw it.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/terminal/session_stream_parser.dart';

void main() {
  test('SOFT wrap (no \\n): parser sees ONE contiguous URL', () {
    final matches = <StreamMatch>[];
    final p = SessionStreamParser(onMatch: matches.add);
    // The decoded stream of a soft-wrapped URL has NO newline mid-URL — the
    // terminal does the wrapping at render time, not the byte stream.
    p.feed(
      'https://github.com/flavordrake/mobissh/releases/tag/native-v0.1.2\n',
    );
    expect(matches, hasLength(1));
    expect(
      matches.single.text,
      'https://github.com/flavordrake/mobissh/releases/tag/native-v0.1.2',
    );
  });

  test('HARD wrap (literal \\n mid-URL): parser sees TWO broken fragments', () {
    final matches = <StreamMatch>[];
    final p = SessionStreamParser(onMatch: matches.add);
    // Source/TUI hard-wrapped the URL with a real newline.
    p.feed('https://github.com/flavordrake/mobissh/releas\n');
    p.feed('es/tag/native-v0.1.2 done\n');
    // The first fragment is a valid URL on its own (scheme + chars), the second
    // is not a URL at all → the FULL URL is NOT recovered. This is why even a
    // stream parser misses the owner's case without a join heuristic.
    final urls = matches.map((m) => m.text).toList();
    expect(
      urls.contains(
        'https://github.com/flavordrake/mobissh/releases/tag/native-v0.1.2',
      ),
      isFalse,
      reason:
          'EVIDENCE: the stream parser ALSO fails the hard-wrap case — the \\n '
          'is a token boundary. Stream detection does not solve the bug; a '
          'continuation-join heuristic does. Got: $urls',
    );
  });
}
