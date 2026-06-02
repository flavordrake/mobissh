// SPIKE diagnostic (#570 Slice 2) — edge cases that could make a soft-wrapped
// URL long-press "do nothing" even though Slice 1 nominally handles soft wrap.
//
// Probes the two most likely real-world failure shapes:
//   1. getText() trailing-space padding bleeding a space INTO the reconstructed
//      logical line at the wrap seam (would split the URL regex match).
//   2. A URL that wraps across THREE rows (long GitHub release URL on a narrow
//      phone terminal) — tap on the MIDDLE wrapped row.

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

import 'package:mobissh/terminal/url_hit_test.dart';

void main() {
  test('reconstructed logical line has NO space injected at the wrap seam', () {
    final term = Terminal(maxLines: 200);
    term.resize(40, 24);
    const url =
        'https://github.com/flavordrake/mobissh/releases/tag/native-v0.1.2';
    term.write('$url\r\n');
    final b = term.buffer;
    var row = -1;
    for (var y = 0; y < b.height; y++) {
      if (b.lines[y].toString().contains('https://')) {
        row = y;
        break;
      }
    }
    final recon = reconstructLogicalLine(b, row);
    // The URL must appear CONTIGUOUSLY in the reconstructed line — if getText()
    // padded the first wrapped row with trailing spaces to view width, the
    // logical line would be "...releas  es/tag..." and the regex would stop.
    expect(
      recon.line.contains(url),
      isTrue,
      reason:
          'reconstructed logical line does not contain the contiguous URL — '
          'wrap seam likely padded with spaces. recon="${recon.line}"',
    );
  });

  test('URL wrapping across 3 rows — tap on the MIDDLE row resolves it', () {
    final term = Terminal(maxLines: 200);
    term.resize(24, 24); // very narrow → 3 wrapped rows for a 65-char URL
    const url =
        'https://github.com/flavordrake/mobissh/releases/tag/native-v0.1.2';
    term.write('$url\r\n');
    final b = term.buffer;
    var first = -1;
    for (var y = 0; y < b.height; y++) {
      if (b.lines[y].toString().contains('https://')) {
        first = y;
        break;
      }
    }
    // Count wrapped continuation rows.
    var wraps = 0;
    while (first + 1 + wraps < b.height &&
        b.lines[first + 1 + wraps].isWrapped) {
      wraps++;
    }
    expect(
      wraps >= 2,
      isTrue,
      reason: 'expected >=3 total rows, got ${wraps + 1}',
    );

    // Tap the middle wrapped row.
    final midRow = first + 1;
    final hit = hitTestUrl(term, CellOffset(0, midRow));
    expect(
      hit?.url,
      url,
      reason: 'tap on a middle wrapped row did not resolve the full URL',
    );
  });
}
