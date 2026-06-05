// Unit tests for [Da2HyperlinkResponder] — the byte-stream interceptor that
// answers tmux's DA2 query as a `tmux`-class terminal so tmux forwards OSC-8
// hyperlinks. See native/lib/ssh/da2_responder.dart.
//
// THE MECHANISM (verified against tmux 3.4): tmux enables the `hyperlinks`
// client feature only when the client answers the DA2 query `ESC [ > c` with
// `ESC [ > 84 ; ... c` (84 = 'T'). tmux honors the FIRST reply, so we must
// SWALLOW the query (the UI terminal would otherwise emit its own `>0` reply
// first) and send ours.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ssh/da2_responder.dart';

Uint8List _b(String s) => Uint8List.fromList(s.codeUnits);
String _s(Uint8List b) => String.fromCharCodes(b);

void main() {
  group('Da2HyperlinkResponder', () {
    test('the tmux reply is ESC [ > 84 ; 0 ; 0 c', () {
      expect(_s(kTmuxDa2Reply), '\x1b[>84;0;0c');
    });

    test('passes ordinary bytes through untouched, no reply', () {
      final r = Da2HyperlinkResponder();
      final res = r.scan(_b('hello world\r\n'));
      expect(_s(res.forward), 'hello world\r\n');
      expect(res.hasReply, isFalse);
      expect(res.replies, isEmpty);
    });

    test('passes other escape sequences (colors, primary DA) through', () {
      final r = Da2HyperlinkResponder();
      // SGR color + primary DA query ESC[?1;2c + cursor move — none is DA2.
      final input = '\x1b[31mred\x1b[0m\x1b[?1;2c\x1b[2A';
      final res = r.scan(_b(input));
      expect(_s(res.forward), input);
      expect(res.hasReply, isFalse);
    });

    test('detects the bare tmux DA2 query ESC[>c, swallows it, replies', () {
      final r = Da2HyperlinkResponder();
      final res = r.scan(_b('before\x1b[>cafter'));
      // Query removed from the forwarded stream.
      expect(_s(res.forward), 'beforeafter');
      // Exactly one tmux reply.
      expect(res.replies, hasLength(1));
      expect(_s(res.replies.first), '\x1b[>84;0;0c');
      expect(r.repliesSent, 1);
    });

    test('tolerates parameterized DA2 queries ESC[>0c and ESC[>0;0c', () {
      for (final q in ['\x1b[>0c', '\x1b[>0;0c', '\x1b[>1;2;3c']) {
        final r = Da2HyperlinkResponder();
        final res = r.scan(_b('x${q}y'));
        expect(_s(res.forward), 'xy', reason: 'query $q should be swallowed');
        expect(res.replies, hasLength(1), reason: 'query $q should reply');
      }
    });

    test('handles the query split across two chunks', () {
      final r = Da2HyperlinkResponder();
      // Split right in the middle of ESC [ > c.
      final res1 = r.scan(_b('out\x1b[>'));
      // The partial query is buffered, not forwarded.
      expect(_s(res1.forward), 'out');
      expect(res1.hasReply, isFalse);

      final res2 = r.scan(_b('cmore'));
      // Completing the query swallows it and replies.
      expect(_s(res2.forward), 'more');
      expect(res2.replies, hasLength(1));
    });

    test('handles the query split byte-by-byte', () {
      final r = Da2HyperlinkResponder();
      final query = '\x1b[>c';
      final collected = StringBuffer();
      var replies = 0;
      for (final byte in [...'A'.codeUnits, ...query.codeUnits, ...'B'.codeUnits]) {
        final res = r.scan(Uint8List.fromList([byte]));
        collected.write(_s(res.forward));
        replies += res.replies.length;
      }
      expect(collected.toString(), 'AB');
      expect(replies, 1);
    });

    test('a lone ESC that is not a DA2 prefix is forwarded', () {
      final r = Da2HyperlinkResponder();
      // ESC followed by a non-[ byte — a different escape. Should pass through.
      final res = r.scan(_b('\x1bM')); // reverse index
      expect(_s(res.forward), '\x1bM');
      expect(res.hasReply, isFalse);
    });

    test('ESC[> that is NOT a DA2 query (different final byte) passes through', () {
      final r = Da2HyperlinkResponder();
      // ESC[>4m is a real sequence (some modifyOtherKeys-ish); final byte != c.
      final res = r.scan(_b('\x1b[>4m'));
      expect(_s(res.forward), '\x1b[>4m');
      expect(res.hasReply, isFalse);
    });

    test('multiple DA2 queries in one chunk each get a reply', () {
      final r = Da2HyperlinkResponder();
      final res = r.scan(_b('\x1b[>ca\x1b[>cb'));
      expect(_s(res.forward), 'ab');
      expect(res.replies, hasLength(2));
      expect(r.repliesSent, 2);
    });

    test('flush returns buffered partial bytes', () {
      final r = Da2HyperlinkResponder();
      final res = r.scan(_b('tail\x1b['));
      expect(_s(res.forward), 'tail');
      // The partial \x1b[ was buffered; flush returns it.
      expect(_s(r.flush()), '\x1b[');
      // Second flush is empty.
      expect(r.flush(), isEmpty);
    });

    test('reset clears pending buffer and counter', () {
      final r = Da2HyperlinkResponder();
      r.scan(_b('\x1b[>')); // buffers a partial
      r.scan(_b('c')); // completes -> reply; counter = 1
      expect(r.repliesSent, 1);
      r.reset();
      expect(r.repliesSent, 0);
      // After reset, a fresh 'c' is just a literal 'c' (no dangling prefix).
      final res = r.scan(_b('c'));
      expect(_s(res.forward), 'c');
      expect(res.hasReply, isFalse);
    });

    test('does not corrupt UTF-8 multibyte content around a query', () {
      final r = Da2HyperlinkResponder();
      // "café" then DA2 then "naïve".
      final bytes = <int>[
        ...utf8.encode('café'),
        ...'\x1b[>c'.codeUnits,
        ...utf8.encode('naïve'),
      ];
      final res = r.scan(Uint8List.fromList(bytes));
      expect(utf8.decode(res.forward), 'cafénaïve');
      expect(res.replies, hasLength(1));
    });
  });
}
