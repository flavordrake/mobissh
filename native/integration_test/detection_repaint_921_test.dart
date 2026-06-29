// #921 — with detect-URLs ON the terminal does NOT repaint on the PRIMARY
// screen; with detection OFF it paints. tmux control mode is OFF and irrelevant.
//
// ROOT (same single-consumption libghostty damage as #900, now on the PRIMARY
// screen): detection ON registers a second libghostty `RenderState` consumer and
// drives an EXTRA content notify per output change, so the render box's frame
// builder syncs the SAME handle twice for one change — the first sync consumes
// the per-row damage, the second reads CLEAN and its partial build re-emits NO
// rows, freezing the grid. The #900 fix's full-re-read gate was alternate-screen
// only, so the primary screen had no guard. FIX (#921): force a full visible-grid
// re-read on the primary screen too, but ONLY while detection is active
// (`TerminalRenderBox.detectionActive`), wired from the URL/path pattern
// registration. #805 streaming perf (detection OFF) is untouched.
//
// This is the device-class assertion a headless test cannot make: it drives the
// REAL SSH→host→flterm chain on the DEFAULT scrape path (control-mode flag OFF),
// detection ON, and asserts that FRESH PTY output with NO user input repaints the
// visible grid (the render box re-reads rows). It also keeps the #805 idle
// no-free-run guard. Reuses the #918 render-box access + connect helpers.
//
// Bridge: scripts/native-connect-test.sh (127.0.0.1:2222 → socat → test-sshd).
// Run: scripts/native-connect-test.sh integration_test/detection_repaint_921_test.dart

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/flterm.dart' show TerminalRenderBox, TerminalRenderer;
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/detection_providers.dart';
import 'package:mobissh/state/sessions.dart';

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
    'scrape path, detection ON: fresh output with NO user input repaints the '
    'primary-screen grid; idle does not free-run (#921)',
    (tester) async {
      FlutterForegroundTask.initCommunicationPort();

      // Default detection settings (all-true) — detection ON, the exact #921
      // failing condition.
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MobisshApp(),
        ),
      );
      await tester.pump(const Duration(seconds: 1));

      // Make sure detection (URLs) is ON for this run regardless of any stored
      // setting from a prior run on the same data dir.
      await container.read(detectionSettingsProvider.notifier).setUrl(true);
      await tester.pump(const Duration(milliseconds: 300));

      await adhocPasswordConnect(
        tester,
        host: '127.0.0.1',
        port: '2222',
        user: 'testuser',
        pass: 'testpass',
      );

      var connected = false;
      for (var i = 0; i < 80; i++) {
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

      // The fix wires detectionActive from the URL/path pattern registration.
      // Give the post-frame wiring a few frames to apply, then assert it is ON.
      for (var i = 0; i < 20 && !box!.detectionActive; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(box!.detectionActive, isTrue,
          reason: 'detectionActive was never wired onto the render box with URL '
              'detection ON — the #921 primary-screen full-re-read guard would '
              'never engage');

      // Let startup output settle so we measure from a QUIET baseline.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }

      // CORE #921 ASSERTION: fresh PTY output with NO user input must repaint the
      // visible grid even with detection ON (the competing detection sync would
      // otherwise consume the damage and freeze the grid). The render box must
      // re-read rows within the settle window after the bytes arrive.
      var repainted = false;
      send('echo DETECT_REPAINT_921\n');
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (box.debugRowsRebuiltLastSync > 0) {
          repainted = true;
          break;
        }
      }
      expect(repainted, isTrue,
          reason: 'with detection ON, fresh output with no user input did NOT '
              'repaint the primary-screen grid (the #921 paint freeze) — the '
              'render box re-read zero rows after new PTY bytes');

      // Stream several more lines (no user input) and confirm the grid keeps
      // repainting — the device repro is streaming output / window churn.
      for (var n = 0; n < 4; n++) {
        send('printf "stream line %d https://example.com/p%d\\n" $n $n\n');
        var sawRebuild = false;
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          if (box.debugRowsRebuiltLastSync > 0) {
            sawRebuild = true;
            break;
          }
        }
        expect(sawRebuild, isTrue,
            reason: 'streaming output line $n with detection ON did not repaint '
                'the grid (#921)');
      }

      // PERF GUARD (#805): with no input and no output, the full re-read must NOT
      // free-run. Let everything settle, then idle and assert the output tick is
      // disarmed (the primary full-re-read fires only on a content notify).
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(box.debugOutputTickArmed, isFalse,
          reason: 'the output tick stayed armed while idle — the #921 primary '
              'full-re-read must fire only on a content notify, never free-run '
              '(the #805 battery guard)');

      debugPrint(
        'DETECT_REPAINT_921 scrape path: detectionActive ON, fresh-output '
        'repaint OK, streaming repaint OK, idle tick disarmed',
      );
    },
  );
}
