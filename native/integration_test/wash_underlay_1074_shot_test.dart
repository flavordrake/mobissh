// On-emulator acceptance for #1074 — the detection WASH is now a LIVE widget
// LAYER ([GhosttyWashLayer]) painted UNDER a TRANSPARENT terminal, NOT the fork's
// render-box highlight pass. This supersedes the #1067/#1069/#1071 render-box
// wash acceptance (which asserted `renderBox.debugWashViewRows` / capsule
// highlights — both gone with the relocation).
//
// The owner's bug: on a continuously-repainting TUI the render-box wash FROZE /
// went stale while the gutter chip (a widget layer) tracked fine. So the
// acceptance here is: the wash LAYER tracks its token LIVE, in LOCKSTEP WITH THE
// GUTTER, through scroll AND churn — every sampled frame the wash's occupied
// viewport rows equal the gutter's rows for the SAME anchors (both resolve from
// the live anchor set + painted offset). Glyphs stay full-contrast because the
// terminal is transparent (backgroundOpacity 0) and the wash sits BELOW it — no
// dimming is possible by construction; a screenshot at churn + settle confirms
// visually.
//
// Bridge: scripts/native-connect-test.sh (127.0.0.1:2222 → socat → test-sshd).
// Run: scripts/native-connect-test.sh integration_test/wash_underlay_1074_shot_test.dart
// Screenshots: fire scripts/emu-shot.sh while a *_WINDOW_OPEN marker is logged.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/detection_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/ghostty_terminal_decorators.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

import 'support/connect_helpers.dart';

const _url = 'https://example.com/track1074';
// A MULTI-segment absolute path — always visible (no #990 short-path suppress).
const _path = '/usr/local/lib/python3.11/site-packages';

/// The wash gate the layer uses, reduced to what needs no verifier: URL / OSC-8
/// / multi-segment path patterns paint a wash. Colour value is irrelevant to the
/// row-tracking assertion — only null-vs-non-null (paints or not) matters here.
Color? _washColorFor(StructuredAnchor a) =>
    ghosttyPatternPaintsWash(a.patternId) ? const Color(0xFF00FF00) : null;

/// The set of viewport rows the WASH LAYER paints this frame — the LIVE
/// resolution the layer performs (`ghosttyResolveWashes` over the controller's
/// current anchors + `anchorRects`), reduced to each capsule's top viewport row.
Set<int> _washRows(
  TerminalController c, {
  required double cellHeight,
  required double padding,
}) {
  final out = <int>{};
  for (final wash in ghosttyResolveWashes(
    c.anchors,
    rectsOf: c.anchorRects,
    washColorFor: _washColorFor,
  )) {
    for (final rect in wash.rects) {
      out.add(((rect.top - padding) / cellHeight).round());
    }
  }
  return out;
}

/// The set of viewport rows the GUTTER paints for the SAME wash-painting anchors
/// (`anchorGutterRow` — the layer the owner reports tracks fine). The wash rows
/// must equal these every frame ("tracks live WITH the gutter").
Set<int> _gutterRowsForWashAnchors(TerminalController c) {
  final out = <int>{};
  for (final a in c.anchors) {
    if (_washColorFor(a) == null) continue;
    for (final range in a.ranges) {
      final r = c.anchorGutterRow(range);
      if (r != null) out.add(r);
    }
  }
  return out;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'the wash LAYER tracks its token LIVE and in LOCKSTEP with the gutter '
    'through scroll AND churn, under a transparent terminal (#1074)',
    (tester) async {
      FlutterForegroundTask.initCommunicationPort();

      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(detectionSettingsProvider.notifier).setEnabled(true);

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

      TerminalController? ctrlOf() =>
          GhosttyTerminalView.debugControllers[sessionId];
      for (var i = 0; i < 40 && ctrlOf() == null; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      final controller = ctrlOf();
      expect(controller, isNotNull, reason: 'no ghostty controller for session');

      final termKey = find.byKey(Key('ghostty-terminal-$sessionId'));
      expect(termKey, findsOneWidget, reason: 'no ghostty terminal view');

      // #1074: the terminal renders TRANSPARENT — the wash below shows through,
      // it CANNOT dim the glyphs (they paint opaque on top). Assert the invariant.
      final renderer = tester.widget<TerminalRenderer>(
        find.descendant(of: termKey, matching: find.byType(TerminalRenderer)),
      );
      expect(renderer.theme.backgroundOpacity, 0.0,
          reason: 'terminal must be transparent so the wash sits BELOW it');
      expect(renderer.theme.backgroundOpacityCells, isFalse,
          reason: 'explicit-bg cells stay opaque and occlude the wash');

      final cellSize = GhosttyTerminalView.debugCellSizes[sessionId];
      expect(cellSize, isNotNull, reason: 'no measured cell size');
      final cellHeight = cellSize!.height;

      final out = <int>[];
      final sub = entry.proxy.output.listen(out.addAll);
      addTearDown(sub.cancel);
      for (var i = 0; i < 40 && out.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(out.isNotEmpty, isTrue, reason: 'no shell prompt — dead PTY');

      // A TALL block of URL anchors + a path, sandwiched mid-history so scrolling
      // back places several washes across the viewport at once.
      entry.proxy.sendInput(
        Uint8List.fromList(utf8.encode(
          'clear; seq 100; for i in \$(seq 1 12); do echo VISIT1074 \$i $_url; '
          'done; echo PATH1074 $_path; seq 200\n',
        )),
      );
      var tailSeen = false;
      for (var i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        if (utf8.decode(out, allowMalformed: true).contains('\n200')) {
          tailSeen = true;
          break;
        }
      }
      expect(tailSeen, isTrue, reason: 'seq 200 output never arrived');
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }

      final rect = tester.getRect(termKey);
      final bodyX = rect.left + rect.width * 0.35;
      var lockstepFrames = 0;

      bool washPaintPresent() =>
          find.byKey(const Key('ghostty-wash-paint')).evaluate().isNotEmpty;

      // Per-frame invariant: the wash layer's rows == the gutter's rows for the
      // SAME anchors (live lockstep), and the wash CustomPaint is mounted while
      // any wash is on-screen (never a frozen/absent layer).
      Future<void> sample(String phase) async {
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 16));
        controller!.reportPaintedViewportOffset(controller.scrollbar.offset);
        final washRows = _washRows(
          controller,
          cellHeight: cellHeight,
          padding: kGhosttyTerminalPadding,
        );
        final gutterRows = _gutterRowsForWashAnchors(controller);
        expect(washRows, equals(gutterRows),
            reason: '[$phase] wash rows $washRows != gutter rows $gutterRows — '
                'the wash is not tracking live WITH the gutter');
        if (gutterRows.isNotEmpty) {
          lockstepFrames++;
          expect(washPaintPresent(), isTrue,
              reason: '[$phase] wash anchors on-screen but the wash layer '
                  'painted nothing (frozen/absent)');
        }
      }

      bool washVisible() => controller!.anchors.any((a) =>
          _washColorFor(a) != null &&
          a.ranges.any((r) => controller.anchorGutterRow(r) != null) &&
          ('${a.payload}'.contains('track1074') ||
              '${a.payload}'.contains('site-packages')));

      // ---- PHASE SCROLL: swipe a wash anchor back on-screen. ----
      var washOnScreen = false;
      for (var s = 0; s < 30 && !washOnScreen; s++) {
        final g = await tester.startGesture(
          Offset(bodyX, rect.top + rect.height * 0.30),
        );
        for (var i = 1; i <= 6; i++) {
          await g.moveTo(
            Offset(bodyX, rect.top + rect.height * (0.30 + 0.09 * i)),
          );
          await sample('swipe$s.move$i');
        }
        await g.up();
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 60));
        }
        await sample('swipe$s.up');
        washOnScreen = washVisible();
      }
      expect(washOnScreen, isTrue,
          reason: 'never scrolled a wash anchor back on-screen');

      // MID-SCROLL screenshot window: small oscillation keeps washes on-screen
      // while they MOVE — an external shot lands on a moving wash, text legible.
      debugPrint('WASH1074_MIDSCROLL_WINDOW_OPEN');
      for (var o = 0; o < 44; o++) {
        final down = (o ~/ 3).isEven;
        final startY = rect.top + rect.height * (down ? 0.40 : 0.60);
        final g = await tester.startGesture(Offset(bodyX, startY));
        for (var i = 1; i <= 3; i++) {
          final dy = rect.height * 0.04 * i * (down ? 1 : -1);
          await g.moveTo(Offset(bodyX, startY + dy));
          await sample('midscroll$o.move$i');
        }
        await g.up();
        for (var i = 0; i < 3; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        await sample('midscroll$o.rest');
        if (!washVisible()) {
          final g2 = await tester.startGesture(
              Offset(bodyX, rect.top + rect.height * 0.35));
          for (var i = 1; i <= 4; i++) {
            await g2.moveTo(
                Offset(bodyX, rect.top + rect.height * (0.35 + 0.10 * i)));
            await sample('midscroll$o.recover$i');
          }
          await g2.up();
          for (var i = 0; i < 4; i++) {
            await tester.pump(const Duration(milliseconds: 50));
          }
        }
      }
      debugPrint('WASH1074_MIDSCROLL_WINDOW_CLOSED');

      // Settle so the churn phase starts from a stable bottom frame.
      entry.proxy.sendInput(Uint8List.fromList(utf8.encode('clear\n')));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }

      // ---- PHASE CHURN: stream output continuously (a live TUI repaint) with a
      // URL in the stream; the wash must stay live + track it each frame. ----
      debugPrint('WASH1074_MIDCHURN_WINDOW_OPEN');
      for (var f = 0; f < 60; f++) {
        if (f % 3 == 0) {
          entry.proxy.sendInput(Uint8List.fromList(
              utf8.encode('echo churn $f see $_url now\n')));
        } else {
          entry.proxy.sendInput(Uint8List.fromList(
              utf8.encode('echo churn $f filler filler filler\n')));
        }
        await sample('churn$f');
      }
      debugPrint('WASH1074_MIDCHURN_WINDOW_CLOSED');

      // Settle + final lockstep check.
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      controller!.reportPaintedViewportOffset(controller.scrollbar.offset);
      expect(controller.isScrolling, isFalse, reason: 'never settled');
      expect(
        _washRows(controller,
            cellHeight: cellHeight, padding: kGhosttyTerminalPadding),
        equals(_gutterRowsForWashAnchors(controller)),
        reason: 'after settle the wash rows must still equal the gutter rows',
      );
      expect(lockstepFrames, greaterThan(20),
          reason: 'too few frames had a visible wash — acceptance is vacuous');
      debugPrint('WASH1074 pass: lockstepFrames=$lockstepFrames '
          '(wash layer in per-frame lockstep with the gutter, scroll AND churn)');

      // Final settled hold for a stationary reference screenshot.
      debugPrint('WASH1074_SETTLED_WINDOW_OPEN');
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      debugPrint('WASH1074_SETTLED_WINDOW_CLOSED');
    },
  );
}
