@Tags(['ffi'])
library;

// INVARIANT (#883, regression of #873): a live detection anchor (URL/path
// highlight) must SURVIVE a scrollback EVICTION shift. libghostty evicts
// history in large page bursts once the buffer hits its cap (observed ≈1139
// rows in one write at cols=40), which moves EVERY absolute `screen` row down
// by the evicted count. #873's synchronous `_pruneStaleDetections()` re-read
// each match's STORED rows — which after the shift address other content (or
// land beyond the live buffer entirely) — found no same-payload match there,
// and EVICTED the anchor before the debounced `_rescanDetections` could
// re-emit corrected coordinates. With the URL more than the bounded window
// (~200 rows) above the tail viewport, the rescan never re-discovers it: the
// loss is PERMANENT. On-device this killed #767 ("highlight tracks scroll
// into scrollback") — the suite-caught `ghostty_url_detection_test.dart`
// failure.
//
// The #883 rule: EVICT ONLY ON CONFIRMED CONTENT CHANGE. The prune trusts the
// stored coordinates only while the frame they were anchored in still holds
// (scrollbackRows has not shrunk, no resize). Under a shifted frame it
// re-locates the same payload at the drop-corrected rows (adopting fresh
// coordinates) or keeps the match for the debounced rescan to re-anchor from
// content. The #873 win is intact: an in-place redraw with different readable
// text (frame unchanged) still evicts synchronously — see
// redraw_anchor_eviction_873_test.dart, which must stay green alongside this.
//
// These tests drive a REAL flterm TerminalController (real libghostty VT
// parser, ffi-tagged) to the actual page-eviction boundary: fill close to the
// cap, anchor a URL near the tail, stream until scrollbackRows visibly DROPS
// (the page eviction), and assert the anchor survives the synchronous prune
// (the KEY pre-debounce read — red on pre-#883 code) and is re-anchored at
// the shifted rows once the rescan settles.

import 'dart:typed_data';

import 'package:flterm/flterm.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Detection re-scan is debounced (~120ms); settle past it before reading.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 250));

  // A short tick that pumps async microtasks/timers but stays WELL UNDER the
  // ~120ms detection debounce — so state observed here reflects the
  // SYNCHRONOUS prune, not the debounced rescan.
  Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 5));

  Uint8List bytes(String s) => Uint8List.fromList(s.codeUnits);

  const url = 'https://example.com/some/path/page';

  // 37-char filler at cols=40. Deliberately LONGER than the 34-char URL row —
  // with a 2-column margin past the scanner's `wrapCol - 1` join slack — so
  // the inferred-wrap-col heuristic keys on the filler shape and never
  // width-joins the URL row with its neighbour. The only mechanism under test
  // here is the coordinate shift from scrollback eviction.
  String filler(int i) => 'f${i.toString().padLeft(5, '0')} ${'x' * 30}';

  // The grid under test: cols=40, rows=6, scrollbackLimit=50. libghostty's
  // page-eviction trip point for this shape is ≈2270 scrollback rows (the
  // limit is page/byte-granular, NOT a row count), evicting ≈1140 rows at
  // once. The fill below stops safely under the trip; the streaming phase
  // then walks to it and DETECTS the eviction from scrollbackRows shrinking —
  // nothing is hardcoded beyond "the trip exists before the loop budget runs
  // out", which is asserted loudly.
  const fillTo = 2150;

  TerminalController newController() {
    final controller = TerminalController(
      config: const TerminalConfig(cols: 40, rows: 6, scrollbackLimit: 50),
    );
    controller.registerTextPattern(TextPattern.url());
    return controller;
  }

  group('#883 — anchors survive the scrollback page-eviction row shift', () {
    test(
      'a URL anchored near the tail SURVIVES the page eviction — the '
      'synchronous prune must not drop it on shifted coordinates (RED on '
      'pre-#883: the prune evicted it before the debounced rescan could '
      'correct, and the bounded rescan never re-found it)',
      () async {
        final controller = newController();
        addTearDown(controller.dispose);

        var lineNo = 0;
        void writeFiller(int n) {
          final sb = StringBuffer();
          for (var i = 0; i < n; i++) {
            sb.write('${filler(lineNo++)}\r\n');
          }
          controller.write(bytes(sb.toString()));
        }

        // Fill close to (but safely under) the page-eviction trip point.
        while (controller.scrollbackRows < fillTo) {
          writeFiller(50);
          await tick();
        }
        controller.write(bytes('$url\r\n'));
        await settle();

        List<StructuredAnchor> urlAnchors() =>
            controller.anchors.where((a) => a.payload == url).toList();

        expect(urlAnchors(), hasLength(1),
            reason: 'precondition: the URL is detected near the tail');
        final rowsBefore = urlAnchors().first.ranges.first.topRow;

        // Stream until the page eviction lands: scrollbackRows SHRINKS in one
        // burst. Chunks stay small and ticks stay far under the debounce, so
        // the synchronous prune is the only detection actor in this loop.
        var maxSb = controller.scrollbackRows;
        var evicted = false;
        for (var chunk = 0; chunk < 40 && !evicted; chunk++) {
          writeFiller(25);
          await tick();
          final sb = controller.scrollbackRows;
          evicted = sb < maxSb;
          if (sb > maxSb) maxSb = sb;
        }
        expect(evicted, isTrue,
            reason: 'precondition: the scrollback page eviction must trip '
                'within the loop budget (scrollbackRows never shrank — '
                'libghostty page accounting changed?)');

        // THE #883 RED ASSERTION: the eviction shifted every absolute row,
        // but the URL's content is alive (it sat far below the evicted page)
        // — the prune must NOT have dropped its anchor. Read BEFORE the
        // debounce (tick-only): pre-#883 the anchor is already gone here.
        expect(urlAnchors(), hasLength(1),
            reason: 'the URL anchor was EVICTED by the synchronous prune on '
                'eviction-shifted coordinates — a coordinate shift is not a '
                'content change (#883)');

        // After the debounced rescan settles, the anchor is re-anchored from
        // content at the SHIFTED rows (the URL stayed within the bounded
        // window of the tail viewport by construction: it was written ~120
        // rows above it).
        await settle();
        expect(urlAnchors(), hasLength(1),
            reason: 'the settled rescan must re-anchor the URL from content');
        final rowsAfter = urlAnchors().first.ranges.first.topRow;
        expect(rowsAfter, lessThan(rowsBefore),
            reason: 'the re-anchored rows must reflect the eviction shift '
                '(absolute rows only ever shift DOWN, toward 0)');
      },
    );

    test(
      'single-line writes at the eviction boundary RE-LOCATE the anchor with '
      'fresh coordinates immediately (the drop-corrected re-locate path, no '
      'debounce wait)',
      () async {
        final controller = newController();
        addTearDown(controller.dispose);

        var lineNo = 0;
        void writeFiller(int n) {
          final sb = StringBuffer();
          for (var i = 0; i < n; i++) {
            sb.write('${filler(lineNo++)}\r\n');
          }
          controller.write(bytes(sb.toString()));
        }

        while (controller.scrollbackRows < fillTo) {
          writeFiller(50);
          await tick();
        }
        controller.write(bytes('$url\r\n'));
        await settle();

        List<StructuredAnchor> urlAnchors() =>
            controller.anchors.where((a) => a.payload == url).toList();

        expect(urlAnchors(), hasLength(1),
            reason: 'precondition: the URL is detected near the tail');
        final rowsBefore = urlAnchors().first.ranges.first.topRow;

        // Walk to the eviction ONE LINE AT A TIME. Each pre-eviction prune
        // re-validates the (trusted) frame and advances the anchor epoch, so
        // when the eviction lands the observable scrollback drop differs from
        // the true shift by only the single appended line — well within the
        // re-locate slack. The prune then finds the same payload at the
        // drop-corrected rows and adopts the FRESH coordinates synchronously.
        var maxSb = controller.scrollbackRows;
        var evicted = false;
        for (var i = 0; i < 250 && !evicted; i++) {
          writeFiller(1);
          await tick();
          final sb = controller.scrollbackRows;
          evicted = sb < maxSb;
          if (sb > maxSb) maxSb = sb;
        }
        expect(evicted, isTrue,
            reason: 'precondition: the page eviction must trip within the '
                'loop budget');

        // Pre-debounce: anchor present AND already at the shifted rows — the
        // re-locate updated the stored ranges without waiting for the rescan.
        expect(urlAnchors(), hasLength(1),
            reason: 'the anchor must survive the eviction-shift prune (#883)');
        final rowsAtEviction = urlAnchors().first.ranges.first.topRow;
        expect(rowsAtEviction, lessThan(rowsBefore),
            reason: 'the surviving anchor should carry the RE-LOCATED rows '
                '(eviction shifts absolute rows down) before the rescan');
      },
    );

    test(
      'ESC[3J (scrollback clear) still removes a scrollback-resident anchor '
      'once the rescan settles — keeping #883 deferral from leaking anchors '
      'for content that is truly gone',
      () async {
        final controller = newController();
        addTearDown(controller.dispose);

        controller.write(bytes('$url\r\n'));
        // Push the URL into scrollback (but nowhere near any cap/window).
        final sb = StringBuffer();
        for (var i = 0; i < 30; i++) {
          sb.write('${filler(i)}\r\n');
        }
        controller.write(bytes(sb.toString()));
        await settle();
        expect(controller.anchors.where((a) => a.payload == url),
            hasLength(1),
            reason: 'precondition: detected with the URL in scrollback');

        // Erase the scrollback. The coordinate frame shrinks, so the prune
        // DEFERS (it cannot confirm anything from shifted coordinates) — but
        // the debounced rescan re-scans real content and must drop the
        // anchor: the URL no longer exists anywhere in the buffer.
        controller.write(bytes('\x1b[3J'));
        await settle();
        expect(controller.anchors.where((a) => a.payload == url), isEmpty,
            reason: 'the scrollback was erased; the settled rescan must drop '
                'the anchor for good');
      },
    );
  });
}
