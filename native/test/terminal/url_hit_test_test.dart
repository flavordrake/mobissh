// Unit tests for the URL hit-test core (#570).
//
// Covers the two pure pieces the feature depends on:
//   1. `urlMatchAt(line, col)` — column containment against the parser's URL
//      regex (the SAME detection as SessionStreamParser).
//   2. `reconstructLogicalLine(buffer, row)` — coalescing soft-wrapped buffer
//      rows back into one logical line, with the per-row column offset so a
//      tapped (row,col) maps into the logical-line column space.
//   3. `hitTestUrl` — resolving a URL (and its logical-column range + start row)
//      from a buffer cell, including a soft-wrapped URL.
//
// These are the device-independent halves of the proof; the on-emulator
// integration test (url_copy_navigate_test.dart) covers the live cell mapping.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/terminal/session_stream_parser.dart';
import 'package:mobissh/terminal/url_hit_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('urlMatchAt', () {
    const line = 'see https://example.com/path for more';
    final urlStart = line.indexOf('https');
    const url = 'https://example.com/path';
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
      final parsed = <StreamMatch>[];
      SessionStreamParser(onMatch: parsed.add).feed('$line\n');
      expect(parsed.single.text, url);
      expect(urlMatchAt(line, urlStart), parsed.single.text);
    });
  });

  group('reconstructLogicalLine', () {
    Terminal makeTerminal(int cols) {
      final t = Terminal(maxLines: 200);
      t.resize(cols, 24);
      return t;
    }

    test('a non-wrapped single line reconstructs verbatim', () {
      final t = makeTerminal(80);
      t.write('hello world\r\n');
      final recon = reconstructLogicalLine(t.buffer, 0);
      expect(recon.line.trimRight(), 'hello world');
      expect(recon.rowStartCol, 0);
      expect(recon.startRow, 0);
    });

    test('a soft-wrapped URL coalesces across rows into one logical line', () {
      final t = makeTerminal(20); // force wrap
      const text = 'x https://example.com/very/long/path/segment/here y';
      t.write(text);
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
      expect(
        recon.line.contains('https://example.com/very/long/path/segment/here'),
        isTrue,
        reason: 'soft-wrapped URL was not coalesced: "${recon.line}"',
      );
      // The reconstructed line starts at the first, non-wrapped row.
      expect(recon.startRow, lessThan(wrappedRow));
      expect(t.buffer.lines[recon.startRow].isWrapped, isFalse);
    });

    test('hitTestUrl resolves a URL on a soft-wrapped row', () {
      final t = makeTerminal(20);
      const url = 'https://example.com/very/long/path/segment/here';
      t.write('x $url y');
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
      // The logical-column range bounds the URL within the coalesced line.
      expect(hit.logicalEnd - hit.logicalStart, url.length);
      expect(hit.lineWidth, 20);
    });

    test('hitTestUrl returns null on a non-URL cell', () {
      final t = makeTerminal(80);
      t.write('just some plain text here\r\n');
      final hit = hitTestUrl(t, const CellOffset(2, 0));
      expect(hit, isNull);
    });
  });
}
