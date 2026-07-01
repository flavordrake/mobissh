@Tags(['ffi'])
library;

// REPLAY diagnostic + regression guard for #868 — "URL not highlighted but a
// line below is, and it doesn't respond to long press" (device 0.1.10+54, which
// already HAS the #863 paint==hit unify). #863 proved paint and hit-test agree
// WITH EACH OTHER, yet the device off-by-1 PERSISTED: paint and hit can be in
// lockstep yet BOTH off from the terminal's REAL rendered glyph row.
//
// This test is STRONGER than the #863 invariant. #863 asserts `anchorRects` and
// `matchAt` resolve to the same match (internal consistency). Here we anchor to
// GROUND TRUTH: we read the REAL replayed grid cells row by row (via the public
// `selection` + `selectedText` block-mode extraction, which formats from the
// `PointTag.screen` ABSOLUTE buffer) to find the row where the URL's GLYPHS
// actually render, then assert:
//
//   1. EVERY PAINT anchor row of the detected URL match lands on a real glyph
//      row, and
//   2. a hit-test (`matchAt`) at the glyph's REAL viewport row resolves the match.
//
// OUTCOME (the honest one): this 32-event capture does NOT reproduce the
// off-by-1. The recorded `scrollTrace` is a single `offset: 0` — the user never
// scrolled, so the #803 "painted offset lags the live offset DURING a tmux-redraw
// scroll" condition the off-by-1 depends on is NOT in this trace. At the captured
// resting frame (and frame-by-frame through it, verified during development) the
// painted offset == the live offset == the glyph row, so paint, hit-test, and
// glyphs all agree (max measured paint/glyph skew across every frame = 0). Per
// the #868 approach (step 3), we do NOT blind-patch geometry off a trace that
// doesn't reproduce the bug. Instead this fixture + test stay as a PERMANENT
// ground-truth guard: if a future change ever skews the paint anchor off the real
// glyph row for THIS captured grid, it turns red. A real fix needs a RICHER
// repro-recording (#790: long-press Feedback → ~10s frame burst) that captures
// the SCROLL the off-by-1 manifests under.
//
// Source: test-results/uploads/2026-06-10T18-28-47-bug-report.byte-trace.json,
// copied verbatim into test/fixtures/replay/url_offby1_868.byte-trace.json. Host
// nv-dev, grid 55x32, scrollTrace offset 0. The frame is a tmux full-screen
// redraw of a Claude digest whose body carries a blue (SGR 94) plain-text URL.

import 'package:flterm/flterm.dart';
import 'package:flutter_test/flutter_test.dart';

import 'replay_trace_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const fixture = 'test/fixtures/replay/url_offby1_868.byte-trace.json';
  // The plain-text URL the Claude digest printed (blue, SGR 94), on its own row.
  const url = 'http://nv-dev.tailbe5094.ts.net:22240/p/top5-draft';
  // A substring UNIQUE to the URL row. The digest's PROSE also mentions
  // `/p/top5-draft`, so we key on the host prefix, which appears only where the
  // actual blue URL renders.
  const urlNeedle = 'http://nv-dev.tailbe5094.ts.net';

  // Build the controller exactly as the app does (#767/#778): same three
  // patterns, same registration order, then replay the captured bytes.
  Future<TerminalController> replay() async {
    final trace = loadByteTrace(fixture);
    final controller = TerminalController(
      config: TerminalConfig(cols: trace.cols, rows: trace.rows),
    );
    controller.registerTextPattern(TextPattern.osc8());
    controller.registerTextPattern(TextPattern.url());
    controller.registerTextPattern(TextPattern.path());
    await replayTrace(controller, trace);
    return controller;
  }

  /// The REAL text of absolute buffer row [absRow], read via the PUBLIC
  /// selection extraction. A single-row BLOCK selection clips to exactly that
  /// row; `selectedText` formats from the `PointTag.screen` absolute buffer —
  /// the SAME absolute frame the detection scan and the match ranges use, so a
  /// glyph row found here is directly comparable to a match's `topRow`.
  String absRowText(TerminalController controller, int absRow, int cols) {
    controller.selection = TerminalSelection(
      startRow: absRow,
      startCol: 0,
      endRow: absRow,
      endCol: cols,
      mode: TerminalSelectionMode.block,
    );
    final text = controller.selectedText();
    controller.clearSelection();
    return text;
  }

  /// The set of absolute rows whose REAL cells carry [needle] (the ground-truth
  /// glyph rows). A tmux full-screen redraw can leave the same content in BOTH
  /// the active screen and scrollback, so there can be more than one.
  Set<int> glyphAbsRowsOf(
    TerminalController controller,
    String needle,
    int cols,
  ) {
    final rows = <int>{};
    for (var absRow = 0; absRow < controller.totalRows; absRow++) {
      if (absRowText(controller, absRow, cols).contains(needle)) rows.add(absRow);
    }
    return rows;
  }

  group('#868 — URL paint anchor must land on the REAL glyph row', () {
    test(
      'the blue plain-text URL is detected as ONE anchor carrying the FULL URL '
      '(so a miss here would be detection, not geometry)',
      () async {
        final controller = await replay();
        addTearDown(controller.dispose);

        final hits = controller.anchors.where((a) => a.payload == url).toList();
        expect(
          hits,
          hasLength(1),
          reason: 'the URL must be ONE detected anchor with the full payload',
        );
      },
    );

    test(
      'every PAINT anchor row of the URL match lands on a REAL glyph row '
      '(no anchor floats a line off the cells — the #868 off-by-1 guard)',
      () async {
        final controller = await replay();
        addTearDown(controller.dispose);

        final trace = loadByteTrace(fixture);
        final cols = trace.cols;

        // Ground truth: the absolute rows whose real cells carry the URL.
        final glyphRows = glyphAbsRowsOf(controller, urlNeedle, cols);
        expect(
          glyphRows,
          isNotEmpty,
          reason: 'the URL glyphs must actually render in the grid; if not, the '
              'fixture/replay is wrong, not the geometry',
        );

        final anchor = controller.anchors.singleWhere((a) => a.payload == url);
        // The match's per-row ranges are ABSOLUTE (PointTag.screen) — the SAME
        // frame as glyphRows. EVERY painted anchor row must coincide with a real
        // glyph row; a range that sits a row off its glyphs IS the off-by-1.
        for (final range in anchor.ranges) {
          expect(
            glyphRows,
            contains(range.topRow),
            reason: 'PAINT ANCHOR vs GLYPH ROW: the match anchors a URL range at '
                'absolute row ${range.topRow} but the URL glyphs render at rows '
                '$glyphRows. An anchor row not in that set paints the highlight a '
                'line off the cells — the #868 off-by-1.',
          );
        }
      },
    );

    test(
      'a hit-test at the URL\'s REAL on-screen viewport row resolves the match '
      '(long-press lands on the highlighted cell)',
      () async {
        final controller = await replay();
        addTearDown(controller.dispose);

        final trace = loadByteTrace(fixture);
        final cols = trace.cols;
        // #958: the on-screen frame base. This capture is a tmux (ALT screen)
        // grid: the alt viewport starts AFTER the primary history in
        // PointTag.screen space, while `scrollbar.offset` is alt-local (0).
        // Filtering "on screen" with the raw offset selected the HISTORY copies
        // of the URL (tmux full-screen redraw leaves duplicates in scrollback)
        // — self-consistent with the OLD broken hit-test base, but those rows
        // are NOT what's painted; that frame is exactly why device long-presses
        // missed (#868) and gutter marks never rendered (#958).
        final base = controller.screenViewportTop;

        // The URL rows that are actually ON SCREEN at the painted viewport.
        final glyphRows = glyphAbsRowsOf(controller, urlNeedle, cols);
        final onScreen = glyphRows
            .where((abs) => abs - base >= 0 && abs - base < trace.rows)
            .toList();
        expect(
          onScreen,
          isNotEmpty,
          reason: 'at least one copy of the URL is on screen at the painted '
              'viewport (screenViewportTop $base)',
        );

        for (final absRow in onScreen) {
          final viewRow = absRow - base;
          final fullRow = absRowText(controller, absRow, cols);
          final startCol = fullRow.indexOf('http://');
          expect(startCol, greaterThanOrEqualTo(0),
              reason: 'the URL starts somewhere on its glyph row');
          final hitCol = startCol + 5; // inside the URL run

          final hit = controller.matchAt(row: viewRow, col: hitCol);
          expect(
            hit?.payload,
            url,
            reason: 'long-press at the URL\'s REAL viewport row '
                '($viewRow,$hitCol) must resolve the URL. If it does not, '
                'matchAt maps via a base '
                '(screenViewportTop=${controller.screenViewportTop}) that has '
                'diverged from the painted rows — the #868 "doesn\'t respond '
                'to long press" / #958 no-marks class.',
          );
        }
      },
    );
  });
}
