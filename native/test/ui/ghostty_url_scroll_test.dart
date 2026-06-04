// #750 (re-framed for #755 Slice 1c) — URL highlight must not float over shifted
// text while scrolling.
//
// ORIGINAL #750: the host overlay re-detected URLs on a debounce for BOTH output
// and scroll, so during a scroll the cached underlines floated over the shifted
// text for the debounce window. The #750 fix was a host-side scroll-vs-output
// discriminator (`ghosttyUrlDetectAction`) that cleared underlines on scroll and
// re-detected on settle.
//
// #755 Slice 1c DELETED that gymnastics. The URL highlight now lives in flterm's
// `controller.highlights` in ABSOLUTE buffer-row space (row 0 == oldest
// scrollback line), and flterm's own painter re-reads the viewport offset each
// frame, mapping each absolute row to viewport row `absRow - viewportOffset`. So
// a highlight ANCHORED at the offset it was detected at TRACKS a scroll for free
// — no clear, no settle, no float. This test pins that structural invariant
// (pure: the row math `ghosttyUrlMatchesToHighlights` + `HighlightRange`), which
// REPLACES the old discriminator. The owner device-validates the on-screen
// behaviour (underline hugs the glyphs on every row, tracks scroll/wrap).

import 'dart:ui';

import 'package:flterm/flterm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';
import 'package:mobissh/ui/ghostty_url_detector.dart';

void main() {
  group('URL highlight tracks scroll via absolute buffer rows (#750/#755)', () {
    const color = Color(0x335B9BD5);
    const match = GhosttyUrlMatch(
      url: 'https://example.com/page',
      startCol: 4,
      startRow: 6,
      endCol: 28,
      endRow: 6,
    );

    // flterm's painter renders an absolute-row range at viewport row
    // `absRow - viewportOffset`. So a range detected on viewport row R at offset
    // O occupies absolute row R + O, and at the SAME offset maps back to R.
    int paintedViewportRow(HighlightRange r, int viewportOffset) =>
        r.topRow - viewportOffset;

    test('detected at offset O, the range paints back at its viewport row', () {
      for (final offset in [0, 5, 40, 137]) {
        final r = ghosttyUrlMatchesToHighlights(
          const [match],
          viewportOffset: offset,
          color: color,
        ).single;
        expect(
          paintedViewportRow(r, offset),
          match.startRow,
          reason: 'offset $offset must round-trip to the detected viewport row',
        );
      }
    });

    test('after a scroll, the SAME range now paints at a shifted viewport row '
        '(it does NOT float at the old row)', () {
      // Detected while pinned at the bottom (offset 100).
      final r = ghosttyUrlMatchesToHighlights(
        const [match],
        viewportOffset: 100,
        color: color,
      ).single;
      // Absolute row is fixed to the content: 6 + 100 = 106.
      expect(r.topRow, 106);
      // User scrolls UP 10 rows → offset 90. flterm re-reads the offset and the
      // SAME range now paints at viewport row 16 (106 - 90), tracking its text
      // upward — NOT stuck floating at viewport row 6.
      expect(paintedViewportRow(r, 90), 16);
      // Scrolls so far the row leaves the viewport (offset 107): the painter
      // simply skips it (viewport row < 0), no stale paint at the old cell.
      expect(paintedViewportRow(r, 107), lessThan(0));
    });

    test('scrollback eviction re-anchors via HighlightRange.scroll', () {
      // When the bounded scrollback drops the oldest N lines, every surviving
      // line's absolute index shifts DOWN by N — `HighlightRange.scroll(-N)`
      // keeps the highlight on its content, preserving the payload.
      final r = ghosttyUrlMatchesToHighlights(
        const [match],
        viewportOffset: 50,
        color: color,
      ).single;
      final shifted = r.scroll(-3);
      expect(shifted.topRow, r.topRow - 3);
      expect(shifted.payload, match.url);
    });
  });
}
