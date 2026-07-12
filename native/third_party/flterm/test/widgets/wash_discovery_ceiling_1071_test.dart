@Tags(['ffi'])
library;

// #1071 (owner P0, build +143) — the DISCOVERY-STARVATION test.
//
// The #1069 rollback restored the pre-#1044 model: DISCOVERY of a new match is
// DEBOUNCED (~120ms) and EVICTION is synchronous. But the debounce is
// cancelled+re-armed on EVERY terminal notify, so a continuously-repainting TUI
// (Claude Code streaming output, a spinner/status line updating faster than the
// debounce window) pushes the trailing edge out forever — `_rescanDetections`
// NEVER fires, no new match is ever discovered, and with synchronous eviction
// the net effect on a busy screen is ZERO washes. The owner's report: "the URLs
// toggle seems to change nothing. bubbles are missing." (+143). This is the same
// starvation #1044-v2 fixed with a max-wait ceiling; the rollback dropped the
// ceiling because it was bundled with the accumulating cache — but they are
// separable.
//
// The #1069 no-accumulation test does NOT catch this: its settle() pumps 200ms
// with NO intervening writes, so the debounce always gets a quiet window to
// fire. This test writes CONTINUOUSLY at sub-debounce intervals — the owner's
// actual environment — and pins:
//   * under continuous <120ms churn the debounce alone stays starved (no anchor
//     after 200ms of churn — proves the bug the ceiling exists to fix);
//   * the max-wait ceiling still forces discovery within _detectionMaxWaitMs,
//     so a URL persistently on screen DOES anchor despite the never-pausing
//     repaint.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/flterm.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

HighlightStyle? _washResolver(StructuredMatch m) {
  if (m.patternId != 'url') return null;
  return const HighlightStyle(background: Color(0x8800FF00), capsule: true);
}

void main() {
  testWidgets(
    'a URL persistently on screen still anchors under continuous sub-debounce '
    'repaint churn — the max-wait ceiling forces discovery the perpetually-'
    'cancelled debounce never delivers (#1071)',
    (tester) async {
      final controller = TerminalController(
        config: const TerminalConfig(cols: 62, rows: 36),
      )
        ..registerTextPattern(TextPattern.url())
        ..detectionHighlightStyleOf = _washResolver;
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 700,
              height: 620,
              child: TerminalView(controller: controller, autofocus: false),
            ),
          ),
        ),
      );
      await tester.pump();

      void write(String s) =>
          controller.write(Uint8List.fromList(utf8.encode(s)));
      void writeRow(int row, String text) => write('\x1b[$row;1H\x1b[2K$text');

      Set<String> liveUrlAnchors() => {
            for (final a in controller.anchors)
              if (a.patternId == 'url') '${a.payload}',
          };

      // A URL that is written ONCE and then left untouched on row 5 for the whole
      // test. It never changes, so it is never a candidate for eviction — the
      // only reason it would fail to anchor is that DISCOVERY never runs.
      const persistentUrl = 'https://example.com/persistent/link';
      writeRow(5, persistentUrl);

      // Drive a spinner on row 8 that repaints every 50ms — FASTER than the 120ms
      // debounce, so every notify cancels the trailing edge. Returns after
      // roughly [ms] of continuous churn.
      const spin = [r'|', r'/', r'-', r'\'];
      Future<void> churn(int ticks) async {
        for (var i = 0; i < ticks; i++) {
          writeRow(8, 'working ${spin[i % spin.length]} tick=$i');
          await tester.pump(const Duration(milliseconds: 50));
        }
      }

      // ---- Phase 1: continuous churn STARVES the plain debounce ----
      // ~200ms of writes 50ms apart: the debounce (120ms) is re-armed before it
      // can ever fire. If this anchored, the test would be vacuous — the point is
      // that WITHOUT the ceiling nothing is discovered here.
      await churn(4);
      expect(
        liveUrlAnchors(),
        isEmpty,
        reason: 'under continuous sub-120ms repaint the debounce is perpetually '
            'cancelled — discovery must not have run yet (if it did, this test '
            'no longer proves the ceiling is what delivers discovery)',
      );

      // ---- Phase 2: keep churning PAST the max-wait ceiling ----
      // The ceiling was armed on the first notify and is NOT re-armed per notify,
      // so it fires ~500ms after churn began even though the debounce never got a
      // quiet window. Churn well past it.
      await churn(12); // ~600ms more of uninterrupted churn (total ~800ms)

      expect(
        liveUrlAnchors(),
        equals({persistentUrl}),
        reason: 'the persistent URL must anchor despite the never-pausing '
            'repaint — the max-wait ceiling (#1071) forces the discovery rescan '
            'the debounce alone would starve forever (owner: "bubbles are '
            'missing" on a continuously-repainting TUI, +143)',
      );

      // Drain the debounce + ceiling armed by the final churn write so no timer
      // is pending at teardown (a quiet window the churn never gave them).
      await tester.pump(const Duration(milliseconds: 600));
      expect(liveUrlAnchors(), equals({persistentUrl}),
          reason: 'the anchor survives once the churn stops');

      debugPrint('WASH1071 discovery-ceiling OK: URL anchored under continuous '
          'sub-debounce churn (ceiling forced the rescan)');
    },
  );
}
