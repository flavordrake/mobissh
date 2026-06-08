@Tags(['ffi'])
library;

// REPLAY regression for #810 — "URL copied but empty" + single-line URL not
// copied — driven by the OWNER'S REAL captured byte trace (not a synthetic grid).
//
// Source: test-results/uploads/2026-06-08T20-47-24-bug-report.byte-trace.json,
// copied into test/fixtures/replay/url_copy_empty_58x34.byte-trace.json. Host
// nv-dev, grid 58x34. The gesture log recorded two `tap-url-copy` events at
// (urlCol,urlRow) = (38,10) and (42,10); the view hit-tests via
// `matchAt(row: urlRow-1, col: urlCol-1)` → (row 9, col 37) and (row 9, col 41),
// which land on the WRAPPED URL spanning rows 9-10. A SECOND, single-line URL
// sits on row 11.
//
// The bug: tapping copied EMPTY (the OSC-8 wrap carried an empty-URI link
// terminator `ESC]8;;ESC\`; an empty-string URI was anchoring a non-null match
// with NO payload). This replay pins that BOTH the wrapped and the single-line
// URL resolve to a NON-EMPTY, FULL URL payload at their tapped cells.

import 'package:flterm/flterm.dart';
import 'package:flutter_test/flutter_test.dart';

import 'replay_trace_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const fixture = 'test/fixtures/replay/url_copy_empty_58x34.byte-trace.json';
  const wrappedUrl =
      'http://nv-dev.tailbe5094.ts.net:22240/p/2026-06-08-david-lesage-prep';
  const singleLineUrl =
      'http://nv-dev.tailbe5094.ts.net:22240/p/david-lesage';

  Future<TerminalController> replay() async {
    final trace = loadByteTrace(fixture);
    final controller = TerminalController(
      config: TerminalConfig(cols: trace.cols, rows: trace.rows),
    );
    // The app registers the SAME three patterns, in the SAME order (#767/#778).
    controller.registerTextPattern(TextPattern.osc8());
    controller.registerTextPattern(TextPattern.url());
    controller.registerTextPattern(TextPattern.path());
    await replayTrace(controller, trace);
    return controller;
  }

  group('REPLAY #810 — URL copy empty / single-line not copied', () {
    test(
      'the WRAPPED URL resolves a NON-EMPTY full payload at the tapped cell '
      '(the "copied but empty" report)',
      () async {
        final controller = await replay();
        addTearDown(controller.dispose);

        // gesture-log tap (38,10) → matchAt(row: 9, col: 37).
        final m = controller.matchAt(row: 9, col: 37);
        expect(m, isNotNull, reason: 'the tap landed ON the wrapped URL');
        expect(
          '${m!.payload}'.trim(),
          isNotEmpty,
          reason: 'the payload must NOT be empty (the #810 empty-copy bug)',
        );
        expect(m.payload, wrappedUrl,
            reason: 'the FULL wrapped URL, not a truncated/empty value');

        // The second tap (42,10) → matchAt(row: 9, col: 41) — same URL.
        final m2 = controller.matchAt(row: 9, col: 41);
        expect(m2, isNotNull);
        expect(m2!.payload, wrappedUrl);
      },
    );

    test(
      'the WRAPPED URL also resolves on its CONTINUATION row (row 10) with the '
      'full payload',
      () async {
        final controller = await replay();
        addTearDown(controller.dispose);
        // Continuation row cells (cols 2..14 carry the tail "-prep").
        final m = controller.matchAt(row: 10, col: 4);
        expect(m, isNotNull, reason: 'the wrapped continuation is hit-testable');
        expect(m!.payload, wrappedUrl);
      },
    );

    test(
      'the SINGLE-LINE URL resolves a NON-EMPTY full payload at its cell (the '
      '"single line didn\'t copy" report)',
      () async {
        final controller = await replay();
        addTearDown(controller.dispose);
        // The single-line URL occupies row 11, cols 2..54.
        final m = controller.matchAt(row: 11, col: 20);
        expect(m, isNotNull, reason: 'the single-line URL must be hit-testable');
        expect('${m!.payload}'.trim(), isNotEmpty);
        expect(m.payload, singleLineUrl);
      },
    );

    test(
      'NO anchor carries an empty payload (an empty-URI OSC-8 link must never '
      'become an empty match)',
      () async {
        final controller = await replay();
        addTearDown(controller.dispose);
        final empties = controller.anchors
            .where((a) => '${a.payload}'.trim().isEmpty)
            .toList();
        expect(empties, isEmpty,
            reason: 'every anchor must carry a real, copyable payload (#810)');
      },
    );
  });
}
