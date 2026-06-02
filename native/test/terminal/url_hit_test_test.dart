// SPIKE (#570/#631) unit tests for the URL hit-test core.
//
// Covers the two pure pieces the spike depends on:
//   1. `urlMatchAt(line, col)` — column containment against the parser's URL
//      regex (the SAME detection as SessionStreamParser).
//   2. `reconstructLogicalLine(buffer, row)` — coalescing soft-wrapped buffer
//      rows back into one logical line, with the per-row column offset so a
//      tapped (row,col) maps into the logical-line column space.
//
// These are the device-independent halves of the proof; the on-emulator
// integration test (url_hittest_spike_test.dart) covers the live cell mapping.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/terminal/session_stream_parser.dart';
import 'package:mobissh/terminal/url_hit_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('urlMatchAt', () {
    const line = 'see https://example.com/path for more';
    // 'see ' is 4 chars; the URL occupies [4, 4+len).
    final urlStart = line.indexOf('https');
    final url = 'https://example.com/path';
    final urlEnd = urlStart + url.length;

    test('a column inside the URL returns the full URL', () {
      expect(urlMatchAt(line, urlStart), url);
      expect(urlMatchAt(line, urlStart + 5), url);
      expect(urlMatchAt(line, urlEnd - 1), url);
    });

    test('a column before the URL returns null', () {
      expect(urlMatchAt(line, 0), isNull);
      expect(urlMatchAt(line, urlStart - 1), isNull);
    });

    test('the column one past the URL end returns null', () {
      expect(urlMatchAt(line, urlEnd), isNull);
    });

    test('out-of-range columns return null', () {
      expect(urlMatchAt(line, -1), isNull);
      expect(urlMatchAt(line, line.length), isNull);
      expect(urlMatchAt('', 0), isNull);
    });

    test('matches the parser regex exactly (single source of truth)', () {
      // The same string fed to the parser yields the same URL.
      final parsed = <StreamMatch>[];
      SessionStreamParser(onMatch: parsed.add).feed('$line\n');
      expect(parsed.single.text, url);
      expect(urlMatchAt(line, urlStart), parsed.single.text);
    });
  });

  group('reconstructLogicalLine', () {
    // Build a Terminal narrow enough that a long URL soft-wraps across rows, so
    // we exercise the isWrapped coalescing path (the WHOLE point of detecting on
    // the logical line, not per rendered row).
    Terminal makeTerminal(int cols) {
      final t = Terminal(maxLines: 200);
      t.resize(cols, 24);
      return t;
    }

    test('a non-wrapped single line reconstructs verbatim', () {
      final t = makeTerminal(80);
      t.write('hello world\r\n');
      // Row 0 holds the text; row index of the written line is 0.
      final recon = reconstructLogicalLine(t.buffer, 0);
      expect(recon.line.trimRight(), 'hello world');
      expect(recon.rowStartCol, 0);
    });

    test('a soft-wrapped URL coalesces across rows into one logical line', () {
      final t = makeTerminal(20); // force wrap
      const text = 'x https://example.com/very/long/path/segment/here y';
      t.write(text);
      // The URL is longer than 20 cols, so it spans multiple buffer rows with
      // isWrapped continuations. Pick a row in the middle of the wrapped run.
      // Find a wrapped row to probe.
      var wrappedRow = -1;
      for (var i = 0; i < t.buffer.lines.length; i++) {
        if (t.buffer.lines[i].isWrapped) {
          wrappedRow = i;
          break;
        }
      }
      expect(
        wrappedRow,
        greaterThan(0),
        reason: 'expected the long URL to soft-wrap (isWrapped continuation)',
      );
      final recon = reconstructLogicalLine(t.buffer, wrappedRow);
      // The coalesced logical line must contain the WHOLE URL contiguously,
      // even though it was split across rendered rows.
      expect(
        recon.line.contains('https://example.com/very/long/path/segment/here'),
        isTrue,
        reason: 'soft-wrapped URL was not coalesced: "${recon.line}"',
      );
    });

    test('hitTestUrl resolves a URL on a soft-wrapped row', () {
      final t = makeTerminal(20);
      const url = 'https://example.com/very/long/path/segment/here';
      t.write('x $url y');
      // Probe a wrapped continuation row at column 0 (mid-URL after coalescing).
      var wrappedRow = -1;
      for (var i = 0; i < t.buffer.lines.length; i++) {
        if (t.buffer.lines[i].isWrapped) {
          wrappedRow = i;
          break;
        }
      }
      expect(wrappedRow, greaterThan(0));
      final hit = hitTestUrl(t, CellOffset(0, wrappedRow));
      expect(hit, isNotNull);
      expect(hit!.url, url);
    });
  });
}
