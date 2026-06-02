// SPIKE (#570 Slice 2) — proves the continuation-join heuristic recovers a
// HARD-wrapped URL (the owner's actual bug) while NOT gluing ordinary wrapped
// paragraph text.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/terminal/wrapped_url_join.dart';

void main() {
  test('recovers the owner-reported hard-wrapped GitHub release URL', () {
    final urls = recoverHardWrappedUrls([
      'https://github.com/flavordrake/mobissh/releas',
      'es/tag/native-v0.1.2 done',
    ]);
    expect(
      urls,
      contains(
        'https://github.com/flavordrake/mobissh/releases/tag/native-v0.1.2',
      ),
    );
  });

  test('recovers a URL hard-wrapped across THREE physical lines', () {
    final urls = recoverHardWrappedUrls([
      'https://example.com/very/long/',
      'path/segment/that/keeps/',
      'going?q=1#frag rest',
    ]);
    expect(
      urls,
      contains(
        'https://example.com/very/long/path/segment/that/keeps/going?q=1#frag',
      ),
    );
  });

  test('does NOT glue ordinary wrapped paragraph words', () {
    // A normal hard-wrapped sentence: no scheme on the left line → no join.
    final urls = recoverHardWrappedUrls(['the quick brown', 'fox jumps over']);
    expect(urls, isEmpty);
  });

  test('does NOT join when the left line has whitespace after the scheme', () {
    // The URL ended on the left line (followed by a word); the next line is a
    // new word, not a continuation. Must not glue.
    final urls = recoverHardWrappedUrls([
      'see https://example.com/path and',
      'then continue reading',
    ]);
    // The complete URL on line 1 is still recovered, but NOT glued to "and...".
    expect(urls, contains('https://example.com/path'));
    expect(
      urls.any((u) => u.contains('andthen')),
      isFalse,
      reason: 'must not glue across a real word boundary',
    );
  });
}
