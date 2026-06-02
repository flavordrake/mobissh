// SPIKE diagnostic (#570 Slice 2) — STEP 1 load-bearing question.
//
// Drives a REAL xterm `Terminal` (not a synthetic surface) to settle whether a
// long URL that the terminal SOFT-WRAPS across display rows is:
//   (a) stored as `isWrapped` continuation rows that Slice 1's
//       `reconstructLogicalLine` already coalesces, OR
//   (b) something the buffer walk misses.
//
// And whether Slice 1's `hitTestUrl` already resolves a tap on a soft-wrapped
// URL. The answer decides fork-vs-index. These tests are diagnostic — they
// ASSERT the behaviour we observe so a regression is visible, and the prose at
// the end of each is the spike's STEP 1 evidence.

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

import 'package:mobissh/terminal/url_hit_test.dart';

void main() {
  group('STEP 1: how does xterm store a soft-wrapped URL', () {
    test(
      'a contiguous long URL (no \\n) wraps into isWrapped continuation rows',
      () {
        // 40-col terminal, a URL longer than 40 chars, written contiguously —
        // exactly the "source has the URL whole, terminal display-wraps it"
        // SOFT case.
        final term = Terminal(maxLines: 200);
        term.resize(40, 24);
        const url =
            'https://github.com/flavordrake/mobissh/releases/tag/native-v0.1.2';
        expect(url.length > 40, isTrue, reason: 'URL must exceed view width');
        term.write('see $url done\r\n');

        final b = term.buffer;
        // Find the first row that contains the scheme.
        var schemeRow = -1;
        for (var y = 0; y < b.height; y++) {
          if (b.lines[y].toString().contains('https://')) {
            schemeRow = y;
            break;
          }
        }
        expect(schemeRow, isNot(-1), reason: 'scheme row not found');

        // The row AFTER the scheme row should be a wrapped continuation (soft
        // wrap), proving xterm stores the contiguous write as isWrapped rows.
        expect(
          b.lines[schemeRow + 1].isWrapped,
          isTrue,
          reason:
              'continuation row is NOT marked isWrapped — buffer walk would '
              'treat the URL tail as a separate logical line',
        );
      },
    );
  });

  group('STEP 1+3: does Slice 1 hitTestUrl resolve a soft-wrapped URL', () {
    test('tap on the WRAPPED TAIL of a soft-wrapped URL resolves full URL', () {
      final term = Terminal(maxLines: 200);
      term.resize(40, 24);
      const url =
          'https://github.com/flavordrake/mobissh/releases/tag/native-v0.1.2';
      term.write('see $url done\r\n');

      final b = term.buffer;
      // Locate the continuation row (the wrapped tail) and a column inside the
      // URL tail on that row.
      var schemeRow = -1;
      for (var y = 0; y < b.height; y++) {
        if (b.lines[y].toString().contains('https://')) {
          schemeRow = y;
          break;
        }
      }
      final tailRow = schemeRow + 1;
      // The tail row begins with the continuation of the URL ("...releas" |
      // "es/tag/..."). col 0 of the tail row is mid-URL.
      final cell = CellOffset(0, tailRow);

      final hit = hitTestUrl(term, cell);
      // This is the crux: if Slice 1 ALREADY resolves a soft-wrapped tail tap,
      // then the production bug is NOT soft wrap — it is the HARD case
      // (source/TUI inserted a real \n). If it returns null, Slice 1's buffer
      // walk is broken for soft wraps and the index approach is warranted.
      expect(
        hit?.url,
        url,
        reason:
            'EVIDENCE: hitTestUrl on a soft-wrapped URL tail returned '
            '${hit?.url}. If null, Slice 1 buffer-walk fails on soft wrap.',
      );
    });

    test('a HARD-wrapped URL (real \\n mid-URL) is BROKEN into two lines', () {
      // The HARD case: the source/TUI itself emitted a newline mid-URL. The
      // terminal stores two SEPARATE logical lines (continuation row is NOT
      // isWrapped). Slice 1's buffer walk cannot rejoin them, and neither can a
      // stream parser without a continuation-join heuristic.
      final term = Terminal(maxLines: 200);
      term.resize(80, 24);
      const head = 'https://github.com/flavordrake/mobissh/releas';
      const tail = 'es/tag/native-v0.1.2';
      term.write('$head\r\n$tail done\r\n');

      final b = term.buffer;
      var headRow = -1;
      for (var y = 0; y < b.height; y++) {
        if (b.lines[y].toString().contains('https://')) {
          headRow = y;
          break;
        }
      }
      // The row after a HARD newline is NOT a wrapped continuation.
      expect(
        b.lines[headRow + 1].isWrapped,
        isFalse,
        reason: 'a real \\n must NOT produce an isWrapped row',
      );
      // And the head row alone does not contain a tappable full URL tail.
      final hit = hitTestUrl(term, CellOffset(0, headRow + 1));
      expect(
        hit?.url,
        isNot(
          'https://github.com/flavordrake/mobissh/releases/tag/native-v0.1.2',
        ),
        reason:
            'EVIDENCE: hard-wrapped URL tail cannot resolve the full URL from '
            'the buffer — needs a continuation-join heuristic (out of scope).',
      );
    });
  });
}
