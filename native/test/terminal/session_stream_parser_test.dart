// Unit tests for the per-session rich-text stream parser (#570, Part A).
//
// `SessionStreamParser` consumes a session's LOGICAL (decoded) text stream —
// chunks of terminal output, NOT per-rendered-line — and detects:
//   - full URLs (robust regex)
//   - a configurable set of additional token regexes (e.g. `/remote/path`,
//     `#hashid`).
// It returns typed `StreamMatch`es carrying the matched TEXT and stable,
// session-absolute logical OFFSETS so a later UI layer can map them to rendered
// cells. Because the parser sits on the logical stream, a URL that WRAPS across
// rendered terminal lines is a single contiguous run of characters here and is
// detected as one match. URLs/tokens split across two fed chunks are coalesced.
//
// Part A is the pure parser + tests only — no session wiring, no UI. The parser
// is structured with a pluggable matcher list so #575's OSC/bell consumer can
// ride the same scan later; that extension is NOT implemented here.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/terminal/session_stream_parser.dart';

void main() {
  group('URL detection (default config)', () {
    test('a single URL in one chunk is detected with correct text', () {
      final matches = <StreamMatch>[];
      final p = SessionStreamParser(onMatch: matches.add);
      p.feed('see https://example.com/path?q=1 for details\n');
      expect(matches, hasLength(1));
      expect(matches.first.kind, StreamMatchKind.url);
      expect(matches.first.text, 'https://example.com/path?q=1');
    });

    test('match offsets are session-absolute and slice back to the URL', () {
      final matches = <StreamMatch>[];
      final p = SessionStreamParser(onMatch: matches.add);
      const text = 'go to http://a.test/x now';
      p.feed(text);
      final m = matches.single;
      // Offsets index into the full logical stream the parser has seen.
      expect(text.substring(m.start, m.end), m.text);
      expect(m.text, 'http://a.test/x');
    });

    test('multiple URLs in one chunk are all detected, in order', () {
      final matches = <StreamMatch>[];
      final p = SessionStreamParser(onMatch: matches.add);
      p.feed('first https://one.example second http://two.example/y end\n');
      expect(matches.map((m) => m.text).toList(), [
        'https://one.example',
        'http://two.example/y',
      ]);
    });

    test('default config detects URLs with no caller-supplied regex', () {
      final matches = <StreamMatch>[];
      final p = SessionStreamParser(onMatch: matches.add);
      p.feed('https://default.example/\n');
      expect(matches.single.kind, StreamMatchKind.url);
      expect(matches.single.text, 'https://default.example/');
    });

    test('trailing sentence punctuation is not captured into the URL', () {
      final matches = <StreamMatch>[];
      final p = SessionStreamParser(onMatch: matches.add);
      p.feed('visit https://example.com/page.\n');
      expect(matches.single.text, 'https://example.com/page');
    });
  });

  group('wrap- and whitespace-margin awareness', () {
    test('a URL surrounded by whitespace margins is detected cleanly', () {
      final matches = <StreamMatch>[];
      final p = SessionStreamParser(onMatch: matches.add);
      p.feed('   \t https://margin.example/path   \t\n');
      expect(matches.single.text, 'https://margin.example/path');
    });

    test(
      'a URL that wraps across rendered lines is one contiguous logical match',
      () {
        // The terminal soft-wraps a long URL across two display rows, but the
        // LOGICAL stream the parser sees has no break inside the URL. The
        // caller is responsible for feeding logical (de-wrapped) text; here we
        // assert the parser treats a contiguous run as a single URL even with
        // line breaks BEFORE and AFTER it (the wrap margins).
        final matches = <StreamMatch>[];
        final p = SessionStreamParser(onMatch: matches.add);
        p.feed('line one\nhttps://wrapped.example/a/very/long/path/segment\nx');
        expect(
          matches.single.text,
          'https://wrapped.example/a/very/long/path/segment',
        );
      },
    );

    test('a newline inside the run terminates the URL (no swallowing)', () {
      final matches = <StreamMatch>[];
      final p = SessionStreamParser(onMatch: matches.add);
      p.feed('https://example.com/a\nnotpartofurl\n');
      expect(matches.single.text, 'https://example.com/a');
    });
  });

  group('chunk-boundary coalescing', () {
    test('a URL split across two feeds is detected once it completes', () {
      final matches = <StreamMatch>[];
      final p = SessionStreamParser(onMatch: matches.add);
      p.feed('open https://split.examp');
      // Nothing emitted yet — the token has not been terminated.
      expect(matches, isEmpty);
      p.feed('le.com/done end\n');
      expect(matches, hasLength(1));
      expect(matches.single.text, 'https://split.example.com/done');
    });

    test(
      'offsets after a split feed are still absolute to the full stream',
      () {
        final matches = <StreamMatch>[];
        final p = SessionStreamParser(onMatch: matches.add);
        const a = 'prefix ';
        const b = 'http://x.test/end ';
        p.feed(a);
        p.feed(b);
        final m = matches.single;
        expect(m.start, a.length);
        expect(m.text, 'http://x.test/end');
      },
    );

    test('the same span is never emitted twice across feeds', () {
      final matches = <StreamMatch>[];
      final p = SessionStreamParser(onMatch: matches.add);
      p.feed('https://once.example/p ');
      p.feed('more text with no url\n');
      expect(matches, hasLength(1));
    });
  });

  group('configurable token regexes', () {
    test('a caller-supplied path regex detects /remote/path tokens', () {
      final matches = <StreamMatch>[];
      final p = SessionStreamParser(
        onMatch: matches.add,
        extraMatchers: [
          RichTextMatcher(
            kind: StreamMatchKind.custom,
            pattern: RegExp(r'(?:/[\w.-]+)+'),
          ),
        ],
      );
      p.feed('cat /remote/path/to/file.txt\n');
      final custom = matches.where((m) => m.kind == StreamMatchKind.custom);
      expect(custom.map((m) => m.text), contains('/remote/path/to/file.txt'));
    });

    test('a caller-supplied hashid regex detects #id tokens', () {
      final matches = <StreamMatch>[];
      final p = SessionStreamParser(
        onMatch: matches.add,
        extraMatchers: [
          RichTextMatcher(
            kind: StreamMatchKind.custom,
            pattern: RegExp(r'#[A-Za-z0-9_]+'),
          ),
        ],
      );
      p.feed('fixed in #abc123 and #def456 today\n');
      expect(
        matches
            .where((m) => m.kind == StreamMatchKind.custom)
            .map((m) => m.text)
            .toList(),
        ['#abc123', '#def456'],
      );
    });

    test('URLs and custom tokens are both emitted from one stream', () {
      final matches = <StreamMatch>[];
      final p = SessionStreamParser(
        onMatch: matches.add,
        extraMatchers: [
          RichTextMatcher(
            kind: StreamMatchKind.custom,
            pattern: RegExp(r'#[A-Za-z0-9_]+'),
          ),
        ],
      );
      p.feed('ref #t100 see https://both.example/p done\n');
      expect(matches.any((m) => m.kind == StreamMatchKind.url), isTrue);
      expect(matches.any((m) => m.kind == StreamMatchKind.custom), isTrue);
    });
  });

  group('partial-then-completed tokens (no false matches)', () {
    test('a custom token split across feeds is not emitted until complete', () {
      final matches = <StreamMatch>[];
      final p = SessionStreamParser(
        onMatch: matches.add,
        extraMatchers: [
          RichTextMatcher(
            kind: StreamMatchKind.custom,
            pattern: RegExp(r'#[A-Za-z0-9_]+'),
          ),
        ],
      );
      p.feed('issue #ab');
      // It LOOKS like a complete token, but more identifier chars may follow;
      // we must not emit a truncated token that then keeps growing.
      p.feed('c123 closed\n');
      final custom = matches
          .where((m) => m.kind == StreamMatchKind.custom)
          .toList();
      expect(custom, hasLength(1));
      expect(custom.single.text, '#abc123');
    });

    test('a non-URL prefix that never completes does not emit', () {
      final matches = <StreamMatch>[];
      final p = SessionStreamParser(onMatch: matches.add);
      p.feed('this mentions http but no scheme://target here\n');
      // "http" alone (no ://) is not a URL.
      expect(matches.where((m) => m.kind == StreamMatchKind.url), isEmpty);
    });
  });

  group('scalability / bounded buffer', () {
    test(
      'large scrollback feeds detect every URL without quadratic blowup',
      () {
        final matches = <StreamMatch>[];
        final p = SessionStreamParser(onMatch: matches.add);
        // Feed many lines, each with a URL, in many small chunks.
        const lines = 2000;
        for (var i = 0; i < lines; i++) {
          p.feed('row $i https://host$i.example/p$i\n');
        }
        final urls = matches
            .where((m) => m.kind == StreamMatchKind.url)
            .toList();
        expect(urls, hasLength(lines));
        // Spot-check a late match's text to ensure offsets/coalescing held up.
        expect(
          urls.last.text,
          'https://host${lines - 1}.example/p${lines - 1}',
        );
      },
    );

    test('internal buffer stays bounded across a long stream', () {
      final p = SessionStreamParser(onMatch: (_) {}, maxBufferChars: 256);
      for (var i = 0; i < 1000; i++) {
        p.feed('a line of plain text number $i with no links at all\n');
      }
      // The rolling buffer must not grow unbounded with stream length.
      expect(p.bufferLength, lessThanOrEqualTo(256));
    });

    test('absolute offset reflects total characters fed, not buffer size', () {
      final matches = <StreamMatch>[];
      final p = SessionStreamParser(onMatch: matches.add, maxBufferChars: 64);
      final filler = 'x' * 500; // pushes past the buffer bound
      p.feed('$filler https://late.example/p\n');
      final m = matches.single;
      // The URL starts right after the filler + one space.
      expect(m.start, filler.length + 1);
      expect(m.text, 'https://late.example/p');
    });
  });
}
