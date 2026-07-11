// On-emulator PROOF for #1031 slice 2 — the Detection Lab tunes a LIVE
// session's affordances.
//
// Flow: connect to test-sshd, print a URL line, wait for its anchor. Open the
// session menu and LONG-PRESS the detection glyph (review change 7 shortcut)
// → the lab root. Open the URL detail: assert the review's gating (no active
// preview/slider for url). Pick the red preset via the shared #1030 picker +
// drag the detected-intensity slider up, then pop back to the terminal and
// assert the LIVE behind-glyph wash (#1045: the controller's baked styled
// highlight ranges) now fills the red hue at a stronger-than-shipped alpha
// (provider → resolver → restyle wiring, no reconnect).
//
// Screenshot windows (the orchestrator runs `scripts/emu-shot.sh <label>`
// while each marker window is open — the PNGs are reviewed for phone-density
// scanability):
//   LAB1031_SHOT_ROOT_OPEN    — lab root (cards + mini previews)
//   LAB1031_SHOT_DETAIL_OPEN  — url detail (pinned preview, recolored)
//   LAB1031_SHOT_SESSION_OPEN — the live session with the recolored wash/chip
//
// Bridge: scripts/native-connect-test.sh (127.0.0.1:2222 → socat → test-sshd).
// Run: scripts/native-connect-test.sh integration_test/detection_lab_1031_test.dart

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/detection_style_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/state/ui_prefs_providers.dart'
    show sessionTerminalThemeProvider;
import 'package:mobissh/ui/ghostty_terminal_decorators.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

import 'support/connect_helpers.dart';

Future<void> _shotWindow(
  WidgetTester tester,
  String label, {
  // Generous: the orchestrator's marker→emu-shot latency ran ~10-15s on the
  // first pass, which pushed every shot one stage late.
  int halfSeconds = 60,
}) async {
  debugPrint('LAB1031_SHOT_${label}_OPEN');
  for (var i = 0; i < halfSeconds; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
  debugPrint('LAB1031_SHOT_${label}_CLOSED');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'lab recolors a live session URL wash/chip immediately (#1031 slice 2)',
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

      final entry = container.read(sessionsProvider).active;
      expect(entry, isNotNull, reason: 'no active session after connect');
      final sessionId = entry!.id;

      TerminalController? controllerOf() =>
          GhosttyTerminalView.debugControllers[sessionId];
      for (var i = 0; i < 40 && controllerOf() == null; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      final controller = controllerOf();
      expect(controller, isNotNull, reason: 'no ghostty controller');

      // Wait for a live shell, then print a URL line.
      final out = <int>[];
      final sub = entry.proxy.output.listen(out.addAll);
      addTearDown(sub.cancel);
      for (var i = 0; i < 40 && out.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(out.isNotEmpty, isTrue, reason: 'no shell prompt — dead PTY');

      const url = 'https://example.com/lab/recolor';
      entry.proxy.sendInput(
        Uint8List.fromList(utf8.encode('echo LAB1031 $url\n')),
      );
      bool urlDetected() => controller!.anchors.any(
        (a) => a.patternId == 'url' && a.payload == url,
      );
      for (var i = 0; i < 40 && !urlDetected(); i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(urlDetected(), isTrue, reason: 'URL anchor never appeared');

      // Review change 7: session menu → LONG-PRESS the detection glyph → lab.
      await tester.tap(find.byKey(const Key('session-menu-button')));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.longPress(
        find.byKey(const Key('session-menu-detection-toggle')),
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        find.byKey(const Key('lab-card-url')),
        findsOneWidget,
        reason: 'long-press must open the lab root',
      );

      await _shotWindow(tester, 'ROOT');

      // URL detail page.
      await tester.tap(find.byKey(const Key('lab-card-tile-url')));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        find.byKey(const Key('lab-detail-preview-detected')),
        findsOneWidget,
      );
      // Review change 1: no dead active controls for url.
      expect(find.byKey(const Key('lab-detail-preview-active')), findsNothing);
      expect(find.byKey(const Key('lab-active-slider')), findsNothing);

      // Recolor: shared #1030 picker, red preset, Apply.
      await tester.tap(find.byKey(const Key('lab-color-row')));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.tap(find.byKey(const Key('color-picker-preset-#e53935')));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byKey(const Key('color-picker-apply')));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      // Stronger detected intensity (drag right; the band is the slider).
      await tester.drag(
        find.byKey(const Key('lab-inactive-slider')),
        const Offset(250, 0),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      final urlStyle = container.read(detectionStylesProvider).of('url');
      expect(urlStyle?.colorHex, '#e53935');
      expect(urlStyle?.inactiveIntensity, isNotNull);
      expect(urlStyle!.inactiveIntensity!, greaterThan(1.0));
      // osc8 carries the same id-level style (one user-facing type).
      expect(
        container.read(detectionStylesProvider).of('osc8')?.colorHex,
        '#e53935',
      );

      await _shotWindow(tester, 'DETAIL');

      // Back to the live terminal (detail → root → terminal).
      await tester.pageBack();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pageBack();
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }

      // THE PROOF (#1045): the live BEHIND-GLYPH wash — the controller's baked
      // styled highlight ranges, painted by the fork under the glyphs — now
      // fills the override: red hue, alpha ABOVE the shipped detected base
      // (intensity > 1), capsule geometry — with no reconnect and no manual
      // refresh (provider → resolver → post-frame restyle wiring).
      HighlightRange? washRange() {
        for (final r in controller!.highlights) {
          if (r.payload == url && r.background != null) return r;
        }
        return null;
      }

      for (var i = 0; i < 20 && washRange() == null; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      final range = washRange();
      expect(range, isNotNull, reason: 'no styled wash range for the URL');
      expect(range!.capsule, isTrue, reason: 'the wash draws the capsule look');
      final wash = range.background!;
      expect(
        wash.r > wash.g && wash.r > wash.b,
        isTrue,
        reason: 'wash must carry the red override hue, got $wash',
      );
      final palette = container.read(sessionTerminalThemeProvider(sessionId));
      final baseDetectedAlpha = ghosttyBubbleWashColor(
        const Color(0xFFE53935),
        verified: false,
        backgroundBrightness: ThemeData.estimateBrightnessForColor(
          palette.theme.background,
        ),
      ).a;
      expect(
        wash.a,
        greaterThan(baseDetectedAlpha),
        reason: 'intensity > 1 must scale the wash alpha up',
      );

      await _shotWindow(tester, 'SESSION');
    },
  );
}
