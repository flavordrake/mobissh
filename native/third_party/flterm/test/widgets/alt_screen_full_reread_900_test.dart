@Tags(['ffi'])
library;

// #900 widget-level pin for the STRUCTURAL fix in
// `TerminalRenderBox._onTerminalChanged`: on the ALTERNATE screen, every
// content-change notify forces `_pipeline.markAllRowsDirty()`, so the next paint
// re-reads the FULL visible grid regardless of libghostty's single-consumption
// per-row damage. This is what makes a tmux window switch repaint on EVERY
// switch instead of every other one (the root: damage consumed by an earlier
// per-switch paint leaves the partial build re-reading nothing).
//
// Headless `tester.pump` coalesces the per-switch notifies into one paint, so it
// cannot reproduce the device's multi-paint damage-consume timing (that red→green
// is the orchestrator's on-emulator tmux confirm). What it CAN pin, and what this
// test asserts, is the fix's production contract: an in-place alt-screen redraw
// re-reads the FULL grid (rows == viewport rows), not just libghostty-damaged
// rows — the property that makes the repaint immune to damage double-consume.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/src/rendering.dart';
import 'package:flterm/src/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart';

void main() {
  testWidgets(
    'an in-place alt-screen redraw re-reads the FULL visible grid each paint '
    '(#900 markAllRowsDirty on alt-screen content change)',
    (tester) async {
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = TerminalController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                height: 128,
                child: TerminalView(controller: controller),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      void write(String s) =>
          controller.write(Uint8List.fromList(utf8.encode(s)));

      write('\x1b[?1049h\x1b[2J\x1b[H');
      await tester.pump();

      final box = tester.renderObject<TerminalRenderBox>(
        find.byType(TerminalRenderer),
      );
      expect(controller.activeScreen, TerminalScreen.alternate,
          reason: 'precondition: alternate screen (tmux/full-screen app)');
      final rows = box.debugRowsRebuiltLastSync; // viewport rows after seed.

      // Seed window A in place (no 2J — tmux rewrites addressed cells only).
      for (var r = 1; r <= rows; r++) {
        write('\x1b[$r;1Hwindow A row $r        ');
      }
      await tester.pump();
      final seededRows = box.debugRowsRebuiltLastSync;
      expect(seededRows, greaterThan(0),
          reason: 'precondition: the seed redraw re-read rows');

      // Each tmux window switch: an in-place redraw of the SAME rows. With the
      // fix, EVERY switch re-reads the FULL visible grid — not a partial subset
      // that a consumed-damage frame could shrink to zero.
      for (var i = 0; i < 4; i++) {
        final tag = i.isEven ? 'B' : 'A';
        for (var r = 1; r <= rows; r++) {
          write('\x1b[$r;1Hwindow $tag row $r        ');
        }
        await tester.pump();
        expect(
          box.debugRowsRebuiltLastSync,
          equals(seededRows),
          reason: 'switch $i (to $tag): the in-place alt-screen redraw must '
              're-read the FULL visible grid ($seededRows rows) on EVERY '
              'switch (#900) — not every other one',
        );
      }
    },
  );

  testWidgets(
    'on the PRIMARY screen, a redraw does NOT force a full re-read (perf: the '
    '#805 partial-rebuild path is preserved off the alternate screen)',
    (tester) async {
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = TerminalController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                height: 128,
                child: TerminalView(controller: controller),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      void write(String s) =>
          controller.write(Uint8List.fromList(utf8.encode(s)));

      // Stay on the PRIMARY screen. Fill it once.
      for (var r = 1; r <= 6; r++) {
        write('\x1b[$r;1Hline $r contents here');
      }
      await tester.pump();

      final box = tester.renderObject<TerminalRenderBox>(
        find.byType(TerminalRenderer),
      );
      expect(controller.activeScreen, TerminalScreen.primary);

      // Change ONE line. On the primary screen the fix must NOT force a
      // full-grid re-read: only the libghostty-damaged rows rebuild (the #805
      // streaming-output perf path). One changed line => fewer rebuilt rows than
      // the full viewport.
      write('\x1b[3;1Hline 3 CHANGED        ');
      await tester.pump();

      final fullRows = box.debugRowsRebuiltLastSync;
      expect(fullRows, lessThan(box.size.height ~/ 16),
          reason: 'a single-line primary-screen change must rebuild fewer rows '
              'than the full viewport — the #900 fix is scoped to the alternate '
              'screen and does not regress #805 partial rebuilds');
    },
  );
}
