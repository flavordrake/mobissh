@Tags(['ffi'])
library;

// INVARIANT (#873): a detection anchor (URL/path highlight) must be RE-VALIDATED
// against the CURRENT grid cells when the grid is redrawn — IMMEDIATELY, not only
// after the debounced full re-scan. A device report (0.1.10+55, "orphaned file
// markups look like folder") described STRAY leftover highlight boxes stuck on
// screen where a path/URL USED to be: the line was redrawn (tmux/app rewrote the
// row with DIFFERENT text) or scrolled out of the bounded scrollback window, yet
// the old anchor still painted over text that no longer contained the match.
//
// ROOT: discovery of new matches is DEBOUNCED (~120ms) and a streaming TUI keeps
// cancelling/pushing the timer, so the stale match lingered in
// `anchors`/`matchAt` (and thus the painted decorator) for the whole debounce
// window — often far longer under continuous output. The fix re-validates live
// anchors against the current cells SYNCHRONOUSLY on each redraw and drops any
// whose cell-run no longer carries the match, so eviction never waits on the
// debounce. (The full bounded-window re-scan still runs, debounced, to DISCOVER
// new matches.)
//
// This facet is headless-reproducible (unlike the #868 during-scroll paint-lag
// that needs a recording): the KEY assertion reads `anchors` BEFORE the debounce
// fires (no settle) — against pre-fix code the stale anchor is still present.
//
// The test drives a REAL flterm TerminalController (real libghostty VT parser,
// ffi-tagged): detect a URL/path, then redraw the row in place with non-matching
// text (or scroll it past the bounded window), and assert the anchor is GONE.

import 'dart:typed_data';

import 'package:flterm/flterm.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Detection re-scan is debounced (~120ms); settle past it before reading.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 250));

  // A short tick that pumps async microtasks/timers but stays WELL UNDER the
  // ~120ms detection debounce — so a stale anchor only survives if the
  // SYNCHRONOUS re-validation (#873) failed to drop it.
  Future<void> tick() =>
      Future<void>.delayed(const Duration(milliseconds: 10));

  Uint8List bytes(String s) => Uint8List.fromList(s.codeUnits);

  // Move the cursor to viewport row [row] (1-based) col 1, erase the line, write
  // [text]. This is how tmux/an app REDRAWS a line in place: absolute cursor
  // position + erase-in-line + new content — no scroll, the content just changes.
  Uint8List redrawRow(int row, String text) =>
      bytes('\x1b[$row;1H\x1b[2K$text');

  const url = 'https://example.com/some/path/page';

  TerminalController newController({int rows = 24, int cols = 80}) {
    final controller = TerminalController(
      config: TerminalConfig(cols: cols, rows: rows),
    );
    controller.registerTextPattern(TextPattern.osc8());
    controller.registerTextPattern(TextPattern.url());
    controller.registerTextPattern(TextPattern.path());
    return controller;
  }

  group('#873 — anchors re-validated against current cells on redraw', () {
    test(
      'a URL row REDRAWN in place is evicted IMMEDIATELY — BEFORE the debounced '
      'rescan fires (the orphaned-box window: this is the #873 RED assertion)',
      () async {
        final controller = newController();
        addTearDown(controller.dispose);

        controller.write(bytes('line one\r\nline two\r\n'));
        controller.write(bytes('$url\r\n'));
        await settle();
        expect(controller.anchors.where((a) => a.payload == url), hasLength(1),
            reason: 'precondition: the URL is detected before the redraw');

        // Redraw the URL's row in place with non-matching prose, then check
        // WITHOUT settling — the debounce has NOT fired. Pre-fix, the stale
        // anchor still paints the orphaned box for the whole debounce window.
        controller.write(redrawRow(3, 'just some prose with no link here'));
        await tick();

        expect(controller.anchors.where((a) => a.payload == url), isEmpty,
            reason: 'the redrawn row no longer holds the URL, so its anchor must '
                'be evicted synchronously — a lingering anchor is the orphaned '
                'box (#873)');

        // matchAt at the redrawn viewport row must also resolve nothing for it.
        final viewRow = 3 - 1 - controller.scrollbar.offset;
        if (viewRow >= 0 && viewRow < 24) {
          final hit = controller.matchAt(row: viewRow, col: 0);
          expect(hit?.payload, isNot(url),
              reason: 'matchAt at the redrawn row must not resolve the gone URL');
        }
      },
    );

    test(
      'a PATH row REDRAWN in place is evicted immediately (pre-debounce)',
      () async {
        final controller = newController();
        addTearDown(controller.dispose);

        const path = '/etc/ssh/sshd_config';
        controller.write(bytes('header\r\n'));
        controller.write(bytes('$path\r\n'));
        await settle();
        expect(controller.anchors.where((a) => a.payload == path), hasLength(1),
            reason: 'precondition: the path is detected');

        controller.write(redrawRow(2, 'plain words only no path'));
        await tick();

        expect(controller.anchors.where((a) => a.payload == path), isEmpty,
            reason: 'the redrawn row no longer holds the path; anchor evicted');
      },
    );

    test(
      'redrawing one match leaves a DIFFERENT, untouched match detected — '
      'eviction is TARGETED, not a blanket clear',
      () async {
        final controller = newController();
        addTearDown(controller.dispose);

        const otherUrl = 'https://keep.me/around';
        controller.write(bytes('$url\r\n'));
        controller.write(bytes('$otherUrl\r\n'));
        await settle();
        expect(controller.anchors.where((a) => a.payload == url), hasLength(1));
        expect(controller.anchors.where((a) => a.payload == otherUrl),
            hasLength(1));

        // Redraw only the FIRST URL's row (viewport row 1).
        controller.write(redrawRow(1, 'no link now'));
        await tick();

        expect(controller.anchors.where((a) => a.payload == url), isEmpty,
            reason: 'the redrawn URL is evicted');
        expect(controller.anchors.where((a) => a.payload == otherUrl),
            hasLength(1),
            reason: 'the untouched URL stays detected — eviction is targeted');
      },
    );

    test(
      'a still-matching redraw KEEPS the anchor (no false eviction when the '
      'redrawn content still carries the URL)',
      () async {
        final controller = newController();
        addTearDown(controller.dispose);

        controller.write(bytes('$url\r\n'));
        await settle();
        expect(controller.anchors.where((a) => a.payload == url), hasLength(1));

        // Redraw the same row with the SAME URL (a benign repaint). The anchor
        // must survive — the prune validates content, it does not blanket-clear
        // on every notify.
        controller.write(redrawRow(1, url));
        await tick();

        expect(controller.anchors.where((a) => a.payload == url), hasLength(1),
            reason: 'a repaint that still carries the URL keeps its anchor');
      },
    );

    test(
      'a URL pushed PAST the bounded scrollback window is evicted (no anchor '
      'lingers for content the scan can no longer see)',
      () async {
        // Small grid; push the URL well past the 200-row bounded window while the
        // viewport stays at the live tail (no scroll-up).
        final controller = newController(rows: 6, cols: 40);
        addTearDown(controller.dispose);

        controller.write(bytes('$url\r\n'));
        await settle();
        expect(controller.anchors.where((a) => a.payload == url), hasLength(1),
            reason: 'precondition: detected at the live tail');

        final filler = StringBuffer();
        for (var i = 0; i < 400; i++) {
          filler.write('filler line $i\r\n');
        }
        controller.write(bytes(filler.toString()));
        await settle();

        expect(controller.anchors.where((a) => a.payload == url), isEmpty,
            reason: 'the URL scrolled past the bounded scan window; its anchor '
                'must be evicted, not linger from a prior scan');
      },
    );
  });
}
