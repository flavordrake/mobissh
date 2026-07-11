// #1044/#1046 — the content-keyed scan cache and anchor-identity reconcile.
//
// Pins the three scheduling invariants the fix introduces:
//   1. PURE SCROLL = ZERO SCANS: viewport movement over already-scanned rows
//      answers from the cache (rescanCacheHits), reading no cells and running
//      no regexes (rescans stays 0 for that phase).
//   2. CONTENT CHANGE = SCOPED RESCAN: a write re-reads only the mutable
//      suffix (grid rows since the last scan) + join context — far fewer rows
//      than the pre-#1044 full ~(viewport + 2×200)-row window.
//   3. UNCHANGED-ROW RESCAN PRESERVES ANCHOR IDENTITY (#1046): a rescan that
//      covers a row whose content did not change re-uses the OLD
//      StructuredMatch INSTANCE, and a reconcile that changes nothing
//      suppresses the decoration notify entirely. That churn (drop +
//      re-create + notify per rescan) was the flickering gutter chip.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/flterm.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _url = 'https://example.com/cached/anchor';

Widget _wrap(TerminalController controller) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 700,
        height: 620,
        child: TerminalView(controller: controller, autofocus: false),
      ),
    ),
  );
}

void _write(TerminalController controller, String s) {
  controller.write(Uint8List.fromList(utf8.encode(s)));
}

Future<void> _settle(WidgetTester tester) async {
  // Detection debounce (~120ms) + scroll settle (~140ms), then a paint, then
  // drain any settle timer the paint itself re-armed (a bottom-follow paint
  // reports a fresh offset → _markScrolling arms 140ms).
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

/// The live StructuredMatch whose payload is [payload], resolved through the
/// public hit-test ([TerminalController.matchAt] returns the INSTANCE the
/// controller holds, so `identical` is meaningful).
StructuredMatch? _matchFor(TerminalController controller, String payload) {
  for (final range in controller.highlights) {
    if (range.payload == payload) {
      final viewRow = range.startRow - controller.screenViewportTop;
      return controller.matchAt(row: viewRow, col: range.startCol);
    }
  }
  return null;
}

void main() {
  testWidgets(
    'pure scroll over scanned rows = cache hits, zero scans; scrolling back '
    'into scanned scrollback re-reads nothing (#1044)',
    (tester) async {
      final controller = TerminalController(
        config: const TerminalConfig(cols: 62, rows: 36),
      );
      addTearDown(controller.dispose);
      controller.registerTextPattern(TextPattern.url());
      await tester.pumpWidget(_wrap(controller));
      await tester.pump();

      _write(controller, '$_url\r\n');
      for (var i = 0; i < 120; i++) {
        _write(controller, 'filler ${i.toString().padLeft(4, '0')} '
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\r\n');
      }
      await _settle(tester);
      expect(controller.anchors.any((a) => a.payload == _url), isTrue);

      final stats = controller.detectionScanStats;
      stats.reset();

      // Scroll to the top and back to the bottom — every row involved was
      // already scanned (120 rows + viewport all fit inside the initial
      // window), so both settle passes must answer from the cache.
      controller.scrollToTop();
      await _settle(tester);
      controller.scrollToBottom();
      await _settle(tester);

      expect(stats.rescans, 0,
          reason: 'viewport movement over scanned rows must read nothing '
              '(got ${stats.snapshot()})');
      expect(stats.rescanRows, 0);
      expect(stats.rescanCacheHits, greaterThan(0),
          reason: 'the settle passes ran and were answered by the cache');
      expect(controller.anchors.any((a) => a.payload == _url), isTrue,
          reason: 'the anchor survives the round trip');
    },
  );

  testWidgets(
    'a content change rescans ONLY the mutable suffix, not the full window '
    '(#1044 scoped rescan)',
    (tester) async {
      final controller = TerminalController(
        config: const TerminalConfig(cols: 62, rows: 36),
      );
      addTearDown(controller.dispose);
      controller.registerTextPattern(TextPattern.url());
      await tester.pumpWidget(_wrap(controller));
      await tester.pump();

      for (var i = 0; i < 300; i++) {
        _write(controller, 'filler ${i.toString().padLeft(4, '0')} '
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\r\n');
      }
      await _settle(tester);

      final stats = controller.detectionScanStats;
      stats.reset();

      _write(controller, 'one new line with $_url in it\r\n');
      await _settle(tester);

      expect(controller.anchors.any((a) => a.payload == _url), isTrue,
          reason: 'the new content is detected');
      expect(stats.rescans, greaterThan(0));
      // The pre-#1044 full window at the bottom of 300 rows of scrollback was
      // ~(200 margin + 36 viewport) = ~236 rows per rescan. The scoped rescan
      // reads the mutable suffix (≤ one viewport of grid rows + the appended
      // line) + join slack — bound it WELL below the old window.
      expect(stats.rescanRows, lessThan(120),
          reason: 'content-driven rescan must be scoped to the mutable '
              'suffix, not the full window (got ${stats.snapshot()})');
    },
  );

  testWidgets(
    'an unchanged row covered by a rescan keeps its match INSTANCE and an '
    'unchanged reconcile suppresses the decoration notify (#1046)',
    (tester) async {
      final controller = TerminalController(
        config: const TerminalConfig(cols: 62, rows: 36),
      );
      addTearDown(controller.dispose);
      controller.registerTextPattern(TextPattern.url());
      await tester.pumpWidget(_wrap(controller));
      await tester.pump();

      // The URL sits INSIDE the grid (no scrollback: a few lines in a 36-row
      // grid) so every content-driven rescan's mutable suffix covers its row,
      // and appends never move the painted offset (no offset-driven notify
      // muddying the assertion below).
      _write(controller, '$_url\r\n');
      _write(controller, 'below the url\r\n');
      await _settle(tester);

      final before = _matchFor(controller, _url);
      expect(before, isNotNull, reason: 'precondition: URL matched');

      final stats = controller.detectionScanStats;
      stats.reset();
      var decorationNotifies = 0;
      controller.decorationListenable.addListener(() => decorationNotifies++);

      // New content on ANOTHER line: the URL row is untouched but lies inside
      // the re-scanned mutable suffix.
      _write(controller, 'tail line, no matches here\r\n');
      await _settle(tester);

      final after = _matchFor(controller, _url);
      expect(after, isNotNull);
      expect(identical(before, after), isTrue,
          reason: 'an unchanged row re-scanned must keep its anchor '
              'IDENTITY — drop/re-create churn is the #1046 chip flicker '
              '(stats: ${stats.snapshot()})');
      expect(stats.matchesReused, greaterThan(0),
          reason: 'the reconcile re-used the existing instance');
      expect(decorationNotifies, 0,
          reason: 'a reconcile that changes no anchor must be invisible to '
              'the gutter/bubble layers (#1046 — no unregister/re-register '
              'churn; stats: ${stats.snapshot()})');
      expect(stats.notifiesSuppressed, greaterThan(0),
          reason: 'the unchanged reconcile was recognised and suppressed');
    },
  );

  testWidgets(
    'a line repainted in place FASTER than the debounce still anchors via the '
    'max-wait ceiling — continuous churn must not starve discovery (#1044)',
    (tester) async {
      final controller = TerminalController(
        config: const TerminalConfig(cols: 62, rows: 36),
      );
      addTearDown(controller.dispose);
      controller.registerTextPattern(TextPattern.url());
      await tester.pumpWidget(_wrap(controller));
      await tester.pump();

      // Repaint the SAME row in place every 100ms (< the 120ms detection
      // debounce), never pausing — a progress bar / spinner / repainting-TUI
      // status line (the owner's Claude-Code TUI). Each write re-arms the
      // trailing debounce, so the PRE-FIX debounce fires NEVER and the URL is
      // never discovered: exactly the on-emulator #1044 acceptance failure
      // ("the repainted line never anchored"). `\r` (no newline) overwrites
      // the current row, so the viewport never scrolls (isScrolling stays
      // false — this is the content-settle path, not the drag-gate) and the
      // URL cells are identical each tick.
      var anchoredDuringChurn = false;
      var anchoredAtIteration = -1;
      for (var i = 0; i < 20; i++) {
        _write(controller, '\r$_url  tick ${i.toString().padLeft(3, '0')}');
        await tester.pump(const Duration(milliseconds: 100));
        if (controller.anchors.any((a) => a.payload == _url)) {
          anchoredDuringChurn = true;
          anchoredAtIteration = i;
          break;
        }
      }

      // #1064: the ceiling keeps a trailing settle armed (so the wash re-shows
      // if the churn stops); drain it so no Timer is pending at teardown.
      await tester.pump(const Duration(milliseconds: 400));

      expect(anchoredDuringChurn, isTrue,
          reason: 'a line repainted faster than the debounce must still '
              'anchor via the max-wait ceiling; the trailing debounce alone '
              'is starved by continuous sub-interval churn and never fires '
              '(#1044 emulator failure)');
      // Ceiling is 300ms; at 100ms/iteration the reconcile must land within a
      // few ticks, well before the 20-iteration (2s) churn window ends. This
      // pins that the ceiling actually bounds the wait (not that the debounce
      // happened to fire during a lucky pause — there are no pauses).
      expect(anchoredAtIteration, lessThan(8),
          reason: 'the max-wait ceiling must force discovery within a bounded '
              'window of continuous churn (anchored at iteration '
              '$anchoredAtIteration)');
    },
  );
}
