// #918 — force-repaint robustness layer, on the SCRAPE path (control-mode flag
// OFF, the shipped default). The "tap Debug fixes it" symptom: the rendered grid
// doesn't repaint until the user taps the Debug overlay (forcing a full Flutter
// frame). This test asserts, end-to-end over the real SSH→host→flterm chain on the
// DEFAULT backend (ghostty/flterm), that the layer self-heals the display:
//
//   1. INPUT-DRIVEN: a user input (a tap routed through the gesture router) leaves
//      the flterm render box NEEDS-PAINT — i.e. the input forced a re-snapshot, the
//      same full repaint the Debug overlay used to be needed for.
//   2. OUTPUT SETTLE TICK ("backend clock"): an output burst forces a frame WITHIN
//      the tick window — the render box's forced-repaint count advances shortly
//      after fresh PTY bytes arrive, even with no further input.
//   3. PERF GUARD (#805): when idle (no input, no output) the settle tick does NOT
//      free-run — the forced-repaint count holds steady and the tick is disarmed.
//
// The shipped build keeps the control-mode flag OFF; this test runs on that default
// scrape path, so it covers the robustness layer as users get it.
//
// Run: scripts/native-connect-test.sh integration_test/force_repaint_robustness_918_test.dart

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/flterm.dart' show TerminalRenderBox, TerminalRenderer;
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart'
    show GhosttyPointerGestureRouter;

import 'support/connect_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // `TerminalRenderBox` is a RenderObject (not a Widget), so it's reached via the
  // `TerminalRenderer` LeafRenderObjectWidget's render object.
  TerminalRenderBox? findRenderBox(WidgetTester tester) {
    final renderers = find.byType(TerminalRenderer);
    if (renderers.evaluate().isEmpty) return null;
    final obj = tester.renderObject(renderers.first);
    return obj is TerminalRenderBox ? obj : null;
  }

  testWidgets(
    'scrape path: input forces a re-snapshot, an output burst forces a frame, '
    'idle does not free-run (#918)',
    (tester) async {
      FlutterForegroundTask.initCommunicationPort();
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MobisshApp(),
        ),
      );
      await tester.pump(const Duration(seconds: 1));

      await adhocPasswordConnect(
        tester,
        host: '127.0.0.1',
        port: '2222',
        user: 'testuser',
        pass: 'testpass',
      );

      var connected = false;
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        final accept = find.text('Trust + connect');
        if (accept.evaluate().isNotEmpty) {
          await tester.tap(accept.first);
          await tester.pump(const Duration(milliseconds: 300));
        }
        if (find.byKey(const Key('session-menu-button')).evaluate().isNotEmpty) {
          connected = true;
          break;
        }
      }
      expect(connected, isTrue, reason: 'never reached the terminal screen');

      final entry = container.read(sessionsProvider).active!;
      void send(String s) =>
          entry.proxy.sendInput(Uint8List.fromList(utf8.encode(s)));

      // Let the shell prompt paint so the flterm render box is laid out.
      final out = <int>[];
      final sub = entry.proxy.output.listen(out.addAll);
      addTearDown(sub.cancel);
      for (var i = 0; i < 40 && out.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(out, isNotEmpty, reason: 'shell never produced output');

      final box = findRenderBox(tester);
      expect(box, isNotNull,
          reason: 'flterm TerminalRenderBox not found — wrong backend? (ghostty '
              'is the default)');

      // Let any startup output settle so we measure from a QUIET baseline.
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }

      // 1) INPUT-DRIVEN: a tap (routed through the gesture router → onTap →
      //    _forceTerminalRepaint) must leave the render box needs-paint, i.e. the
      //    forced-repaint count advances on input.
      final forcedBeforeTap = box!.debugForceRepaintCount;
      await tester.tap(find.byType(GhosttyPointerGestureRouter).first,
          warnIfMissed: false);
      await tester.pump();
      expect(box.debugForceRepaintCount, greaterThan(forcedBeforeTap),
          reason: 'a tap did not force a re-snapshot (input-driven repaint) — the '
              'view would stay stale until a Debug-overlay tap');

      // 2) OUTPUT SETTLE TICK: fresh PTY output must force a frame WITHIN the tick
      //    window (~80ms) even with NO further input.
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      final forcedBeforeOutput = box.debugForceRepaintCount;
      send('echo FORCE_REPAINT_918\n');
      // Wait for the bytes to arrive + the settle window to elapse.
      var ticked = false;
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (box.debugForceRepaintCount > forcedBeforeOutput) {
          ticked = true;
          break;
        }
      }
      expect(ticked, isTrue,
          reason: 'an output burst did not force a frame via the settle tick — '
              'the backend-clock half of the robustness layer');

      // 3) PERF GUARD (#805): with no input and no output, the tick must NOT
      //    free-run. Let everything settle, then idle for many frames and assert
      //    the forced count holds steady and the tick is disarmed.
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      final forcedAtIdleStart = box.debugForceRepaintCount;
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(box.debugForceRepaintCount, forcedAtIdleStart,
          reason: 'the settle tick free-ran while idle — regresses the #805 '
              'battery guard (idle must be zero repaints)');
      expect(box.debugOutputTickArmed, isFalse,
          reason: 'the output tick stayed armed while idle (free-run risk)');

      debugPrint(
        'FORCE_REPAINT_918 scrape path: input-driven OK, output tick OK, '
        'idle steady at ${box.debugForceRepaintCount} forced repaints',
      );
    },
  );
}
