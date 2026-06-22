@Tags(['ffi'])
library;

// #921 widget-level pin for the PRIMARY-screen detection-active full re-read.
//
// With structured-text detection ON, the controller registers a SECOND
// libghostty `RenderState` handle that consumes the shared terminal's per-row
// damage on the same synchronous content notify (it registers its listener
// BEFORE the render box), starving the render box's partial build so the
// primary screen stops repainting. The #921 fix sets
// [TerminalRenderBox.detectionActive], which — mirroring the #900 alternate-
// screen decoupling — forces a FULL visible-grid re-read on each primary-screen
// content change, immune to that single-consumption damage race.
//
// This test asserts the flterm production contract that the app layer relies on:
//   1. detectionActive = true => a primary-screen content change re-reads the
//      FULL visible grid (rows == viewport rows), not just libghostty-damaged
//      rows. (RED before the fix: the gate was alternate-screen-only.)
//   2. detectionActive = false (the detection-OFF control) => a single-line
//      change rebuilds FEWER rows than the viewport (the #805 partial path is
//      preserved — OFF still works).
//
// Headless `tester.pump` coalesces notifies into one paint and does not exercise
// the device's multi-handle damage-consume timing (the orchestrator's on-emulator
// detection-ON confirm covers that). What it pins is the property that makes the
// repaint immune: the full re-read when detection is active.
//
// Reach the render box via `tester.renderObject<TerminalRenderBox>(find.byType(
// TerminalRenderer))` — `find.byType(TerminalRenderBox)` fails (it's a
// RenderObject, not a Widget).

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/src/foundation/structured_text.dart';
import 'package:flterm/src/rendering.dart';
import 'package:flterm/src/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart';

void main() {
  Future<(TerminalController, TerminalRenderBox)> mount(
    WidgetTester tester,
  ) async {
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
              height: 160,
              child: TerminalView(controller: controller),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final box = tester.renderObject<TerminalRenderBox>(
      find.byType(TerminalRenderer),
    );
    return (controller, box);
  }

  testWidgets(
    'detection ACTIVE: a primary-screen content change re-reads the FULL '
    'visible grid (#921 — immune to the detection handle damage-consume)',
    (tester) async {
      final (controller, box) = await mount(tester);
      void write(String s) =>
          controller.write(Uint8List.fromList(utf8.encode(s)));

      expect(controller.activeScreen, TerminalScreen.primary,
          reason: 'precondition: primary screen (normal shell, not tmux)');

      // Seed the screen (more rows than fit, to fill the viewport).
      for (var r = 1; r <= 12; r++) {
        write('\x1b[$r;1Hseed line $r contents');
      }
      await tester.pump();
      expect(box.debugRowsRebuiltLastSync, greaterThan(1),
          reason: 'precondition: the seed re-read more than one row');

      // Detection registered: this is what the app's _registerUrlPattern wiring
      // sets when at least one detect pattern is active. The setter forces an
      // immediate full re-read; capture that count as the FULL-viewport baseline
      // (the render box's true visible-row count, which is not exactly
      // height ~/ cellHeight due to partial-row rendering).
      controller.registerTextPattern(TextPattern.url());
      box.detectionActive = true;
      await tester.pump();
      expect(box.debugDetectionActive, isTrue);
      final fullViewportRows = box.debugRowsRebuiltLastSync;
      expect(fullViewportRows, greaterThan(1),
          reason: 'precondition: a full re-read covers more than one row so it '
              'is distinguishable from a single-row partial rebuild');

      // FRESH output (a URL line) — change ONE row, no user input. With
      // detection active the primary screen must re-read the FULL visible grid
      // even though detection drives the extra consuming sync.
      write('\x1b[3;1Hvisit https://example.com/issue/921 now ');
      await tester.pump();

      expect(
        box.debugRowsRebuiltLastSync,
        equals(fullViewportRows),
        reason: 'with detection active, a single-row primary-screen content '
            'change re-reads the FULL visible grid ($fullViewportRows rows) — '
            'not the partial subset a consumed-damage frame shrinks to zero (the '
            '#921 paint freeze)',
      );

      // Drain the controller's detection-rescan timer so it does not leak past
      // teardown (registering a pattern arms a ~120ms rescan).
      await tester.pump(const Duration(milliseconds: 200));
    },
  );

  testWidgets(
    'detection OFF (control): a single-line primary-screen change rebuilds '
    'FEWER rows than the viewport (the #805 partial path is preserved)',
    (tester) async {
      final (controller, box) = await mount(tester);
      void write(String s) =>
          controller.write(Uint8List.fromList(utf8.encode(s)));

      expect(controller.activeScreen, TerminalScreen.primary);
      expect(box.debugDetectionActive, isFalse,
          reason: 'precondition: detection is OFF by default');

      for (var r = 1; r <= 8; r++) {
        write('\x1b[$r;1Hline $r contents here');
      }
      await tester.pump();

      // Change ONE line with detection OFF: the partial path must rebuild fewer
      // rows than the full viewport — proving the fix does not regress #805 and
      // that the detection-OFF path works (the user's "OFF paints" observation).
      write('\x1b[4;1Hline 4 CHANGED        ');
      await tester.pump();

      final fullViewportRows = box.size.height ~/ 16;
      expect(
        box.debugRowsRebuiltLastSync,
        lessThan(fullViewportRows),
        reason: 'a single-line primary-screen change with detection OFF must '
            'rebuild fewer rows than the full viewport — the #921 full re-read '
            'is gated on detectionActive and does not regress #805',
      );
    },
  );

  testWidgets(
    'turning detection ACTIVE self-heals: it forces an immediate full re-read '
    'so a frame the detection handle already starved repaints (#921 live toggle)',
    (tester) async {
      final (controller, box) = await mount(tester);
      void write(String s) =>
          controller.write(Uint8List.fromList(utf8.encode(s)));

      // Seed (fill the viewport) and capture the full re-read row count.
      for (var r = 1; r <= 12; r++) {
        write('\x1b[$r;1Hbaseline row $r');
      }
      await tester.pump();
      final fullViewportRows = box.debugRowsRebuiltLastSync;
      expect(fullViewportRows, greaterThan(1),
          reason: 'precondition: the seed re-read the full viewport');

      // Flip detection ON. The setter forces markAllRowsDirty + a frame, so the
      // very next paint re-reads the full grid even with no new terminal output.
      controller.registerTextPattern(TextPattern.url());
      box.detectionActive = true;
      await tester.pump();

      expect(
        box.debugRowsRebuiltLastSync,
        equals(fullViewportRows),
        reason: 'flipping detectionActive ON forces an immediate full visible-'
            'grid re-read ($fullViewportRows rows) so a frame the detection '
            'handle already starved heals (the live-toggle case)',
      );

      // Drain the controller's detection-rescan timer (armed by the pattern
      // registration) so it does not leak past teardown.
      await tester.pump(const Duration(milliseconds: 200));
    },
  );
}
