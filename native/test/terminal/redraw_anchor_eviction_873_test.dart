@Tags(['ffi'])
library;

// INVARIANT (#873, amended by #1046): a detection anchor (URL/path highlight)
// must be RE-VALIDATED against the CURRENT grid cells when the grid is
// redrawn, and a stale anchor must be evicted on a BOUNDED clock that does
// NOT depend on the debounced rescan. A device report (0.1.10+55, "orphaned
// file markups look like folder") described STRAY leftover highlight boxes
// stuck on screen where a path/URL USED to be: discovery of new matches is
// DEBOUNCED (~120ms) and a streaming TUI keeps cancelling/pushing the timer,
// so the stale match lingered in `anchors`/`matchAt` for seconds.
//
// #1046 AMENDMENT: eviction is no longer INSTANTANEOUS — an in-place TUI
// repaint routinely leaves a notify observable between a row's erase and its
// redraw, and instant eviction + debounced rediscovery was the flickering
// gutter chip (vanish→reappear 0.2–1.4s in the owner byte-trace). A missed
// anchor now rides a bounded MISS GRACE (~350ms span / ~1.5s block) during
// which it is retried (validate/relocate) on every notify; if the payload
// stays gone the grace timer evicts it — INDEPENDENT of the debounce, so the
// #873 orphan stays bounded even under a stream that pushes the debounce out
// forever. These tests pin exactly that: eviction lands within the grace
// bound WHILE a stream keeps the debounce from ever firing.

import 'dart:typed_data';

import 'package:flterm/flterm.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Detection re-scan is debounced (~120ms); settle past it before reading.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 250));

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

  // Keep the detection debounce PERPETUALLY pushed out (chunks < 120ms apart,
  // rewriting an unrelated bottom row) while real time crosses the ~350ms miss
  // grace — the #873 streaming-TUI shape. Eviction observed during this stream
  // proves it is grace-driven, not debounce-driven.
  Future<void> streamPastGrace(TerminalController controller,
      {int rows = 24}) async {
    for (var i = 0; i < 8; i++) {
      controller.write(
        bytes('\x1b[$rows;1H\x1b[2Kstream tick $i'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 90));
    }
  }

  group('#873 — anchors re-validated against current cells on redraw', () {
    test(
      'a URL row REDRAWN in place is evicted within the bounded miss grace — '
      'while a stream keeps the debounced rescan from EVER firing (the #873 '
      'orphaned-box bound, #1046-amended)',
      () async {
        final controller = newController();
        addTearDown(controller.dispose);

        controller.write(bytes('line one\r\nline two\r\n'));
        controller.write(bytes('$url\r\n'));
        await settle();
        expect(controller.anchors.where((a) => a.payload == url), hasLength(1),
            reason: 'precondition: the URL is detected before the redraw');

        // Redraw the URL's row in place with non-matching prose, then stream
        // sub-debounce chunks for ~720ms: the debounce never fires, real time
        // crosses the ~350ms grace — the orphan must be gone.
        controller.write(redrawRow(3, 'just some prose with no link here'));
        await streamPastGrace(controller);

        expect(controller.anchors.where((a) => a.payload == url), isEmpty,
            reason: 'the redrawn row no longer holds the URL: its anchor must '
                'be evicted within the miss grace even though the stream '
                'keeps pushing the debounce out — a longer-lived anchor is '
                'the #873 orphaned box');

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
      'a PATH row REDRAWN in place is evicted within the miss grace',
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
        await streamPastGrace(controller);

        expect(controller.anchors.where((a) => a.payload == path), isEmpty,
            reason: 'the redrawn row no longer holds the path; anchor evicted '
                'within the grace bound');
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
        await streamPastGrace(controller);

        expect(controller.anchors.where((a) => a.payload == url), isEmpty,
            reason: 'the redrawn URL is evicted (within the grace bound)');
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
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(controller.anchors.where((a) => a.payload == url), hasLength(1),
            reason: 'a repaint that still carries the URL keeps its anchor');
      },
    );

    test(
      'a row MOVED by an in-place repaint keeps its anchor at the NEW rows in '
      'the same notify — no vanish/reappear gap (#1046 atomic relocate)',
      () async {
        final controller = newController();
        addTearDown(controller.dispose);

        controller.write(bytes('above\r\n'));
        controller.write(bytes('$url\r\n'));
        await settle();
        expect(controller.anchors.where((a) => a.payload == url), hasLength(1));
        final oldTop = controller.anchors
            .firstWhere((a) => a.payload == url)
            .ranges
            .first
            .topRow;

        // One chunk: erase the URL's row AND redraw the URL two rows lower —
        // the TUI line-move shape. The anchor must be present at the new rows
        // IMMEDIATELY after the write (no debounce wait).
        controller.write(
          bytes('\x1b[2;1H\x1b[2Kmoved away\x1b[4;1H\x1b[2K$url'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));

        final anchorsNow =
            controller.anchors.where((a) => a.payload == url).toList();
        expect(anchorsNow, hasLength(1),
            reason: 'the moved URL must stay anchored with NO gap (#1046)');
        expect(anchorsNow.first.ranges.first.topRow, isNot(oldTop),
            reason: 'and at its NEW rows (relocated, not stale)');
      },
    );

    test(
      'a URL pushed PAST the bounded scan coverage is evicted (no anchor '
      'lingers for content the scan can no longer vouch for)',
      () async {
        // Small grid; push the URL well past the scan window while the
        // viewport stays at the live tail (no scroll-up). The URL's last scan
        // saw it as a GRID row (mutable), so the one-burst flood dirties the
        // whole coverage — the settled rescan covers only the new window and
        // the out-of-coverage anchor is dropped. (#1044 note: had the URL
        // been scanned while already IN scrollback — the scrolled-through
        // case — the immutable-row cache would legitimately retain it; see
        // detection_scan_cache_1044_test.dart in the fork.)
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
        // Past the grace-sized dust window too (the drop is a coverage trim,
        // not a grace eviction, but keep the read deterministic).
        await Future<void>.delayed(const Duration(milliseconds: 500));

        expect(controller.anchors.where((a) => a.payload == url), isEmpty,
            reason: 'the URL scrolled past the scanned coverage; its anchor '
                'must not linger');
      },
    );
  });
}
