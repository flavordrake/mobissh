// On-emulator acceptance for #1062 (owner P0) — the detection WASH must NOT be
// PINNED during scroll. The owner saw the behind-glyph wash paint once and then
// stay locked to a screen position while content scrolled past it (a pale band
// over "four-layer defense.", not its token). ROOT: the wash's baked ABSOLUTE
// rows are re-aligned to their token by the rescan/relocate, but that reconcile
// is DEFERRED while scrolling for perf (#1044), so mid-scroll the band can
// address stale cells. FIX (the #988 bubble stance ported to the fill): HIDE the
// wash while the painted offset is in flight and re-show it on settle at the
// correct offset.
//
// This drives a REAL SSH → shell → flterm chain: print a URL + a multi-segment
// path SANDWICHED mid-history, then SWIPE-scroll it back on-screen and oscillate.
// Through the scroll it asserts, against the REAL device paint stack:
//   * mid-scroll (isScrolling) the render layer SUPPRESSES the wash
//     (renderBox.debugWashSuppressed) — the hide-on-scroll path fires, and
//   * on any NON-scrolling (settled/paused) frame every on-screen capsule wash
//     sits on its token's real glyph cells (never a pinned band over blank /
//     wrong cells).
// Then it HOLDS for external screenshots (mid-scroll = wash hidden; settled =
// wash on its tokens) that the orchestrator reviews.
//
// Bridge: scripts/native-connect-test.sh (127.0.0.1:2222 → socat → test-sshd).
// Run: scripts/native-connect-test.sh integration_test/wash_hide_on_scroll_1062_shot_test.dart

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
import 'package:mobissh/ui/ghostty_terminal_view.dart';

import 'support/connect_helpers.dart';

const _url = 'https://example.com/track1062';
const _path = '/usr/local/lib/python3.11/site-packages';

/// Every ON-SCREEN capsule wash cell-run that currently sits over cells NOT
/// holding (part of) its payload, mapped at [offset]. Empty == every visible
/// wash is on its token's glyphs (a stale/pinned band fails this).
List<String> _driftedWashes(TerminalController c, int offset) {
  final visible = c.scrollbar.visible;
  final out = <String>[];
  for (final r in c.highlights) {
    if (!r.capsule) continue;
    final payload = '${r.payload}';
    for (var absRow = r.topRow; absRow <= r.bottomRow; absRow++) {
      final viewRow = absRow - offset;
      if (viewRow < 0 || viewRow >= visible) continue;
      final rowText = c.visibleRowsText(viewRow, viewRow);
      final startCol = absRow == r.topRow ? r.topCol : 0;
      final endCol = absRow == r.bottomRow ? r.bottomCol : rowText.length;
      final s = startCol.clamp(0, rowText.length);
      final e = endCol.clamp(0, rowText.length);
      final slice = (e > s ? rowText.substring(s, e) : '').trim();
      final onGlyph =
          slice.isNotEmpty && (payload.contains(slice) || slice.contains(payload));
      if (!onGlyph) out.add('view=$viewRow "$slice" payload=$payload');
    }
  }
  return out;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'the detection wash HIDES while scrolling and re-shows on its tokens at '
    'settle — never a pinned band mid-scroll (#1062)',
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

      // Reach the session's render box so we can read the REAL paint-layer
      // wash-suppression state (debugWashSuppressed).
      final termKey = find.byKey(Key('ghostty-terminal-$sessionId'));
      expect(termKey, findsOneWidget, reason: 'no ghostty terminal view');
      TerminalRenderBox renderBox() => tester.renderObject<TerminalRenderBox>(
            find.descendant(of: termKey, matching: find.byType(TerminalRenderer)),
          );

      // Wait for a live shell prompt.
      final out = <int>[];
      final sub = entry.proxy.output.listen(out.addAll);
      addTearDown(sub.cancel);
      for (var i = 0; i < 40 && out.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(out.isNotEmpty, isTrue, reason: 'no shell prompt — dead PTY');

      // Anchors SANDWICHED mid-history (100 lines either side) so scrolling back
      // to them can place the wash at ANY viewport row.
      entry.proxy.sendInput(
        Uint8List.fromList(utf8.encode(
          'clear; seq 100; echo VISIT1062 $_url; echo PATH1062 $_path; seq 200\n',
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

      var sawWashHiddenMidScroll = false;
      var driftWorst = <String>[];
      var checkedSettledFrames = 0;

      // Sample the wash invariant at the CURRENT frame: mid-scroll the render
      // layer must SUPPRESS the wash (hidden); on a settled/paused frame every
      // visible wash must sit on its token.
      Future<void> sample(String phase) async {
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 16));
        controller!.reportPaintedViewportOffset(controller.scrollbar.offset);
        final scrolling = controller.isScrolling;
        final suppressed = renderBox().debugWashSuppressed;
        final hasWash = controller.highlights.any((r) => r.capsule);
        if (scrolling && suppressed && hasWash) sawWashHiddenMidScroll = true;
        if (!scrolling) {
          checkedSettledFrames++;
          final drift =
              _driftedWashes(controller, controller.paintedViewportOffset);
          if (drift.isNotEmpty && drift.length > driftWorst.length) {
            driftWorst = drift;
          }
          expect(
            drift,
            isEmpty,
            reason: '[$phase] a VISIBLE wash sat off its token on a settled '
                'frame (the #1062 pinned wash): $drift',
          );
        }
      }

      // PHASE 1: swipe-scroll back up until a wash anchor re-enters the window.
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
        washOnScreen = controller!.highlights.any((r) =>
            r.capsule &&
            ('${r.payload}'.contains('track1062') ||
                '${r.payload}'.contains('site-packages')));
        debugPrint('WASH1062 swipe$s: oPaint=${controller.paintedViewportOffset} '
            'isScrolling=${controller.isScrolling} '
            'washOnScreen=$washOnScreen '
            'washHiddenForScroll=${controller.detectionScanStats.washHiddenForScroll}');
      }
      expect(washOnScreen, isTrue,
          reason: 'never scrolled a wash anchor back on-screen — cannot assert');

      // MID-SCROLL screenshot window: slow continuous oscillation so the
      // external emu-shot lands on an in-flight scroll — the wash must be HIDDEN
      // (no pale band riding a fixed screen row). Assertions run throughout.
      debugPrint('WASH1062_MIDSCROLL_WINDOW_OPEN');
      for (var o = 0; o < 24; o++) {
        final down = o.isEven;
        final startY = rect.top + rect.height * (down ? 0.35 : 0.65);
        final g = await tester.startGesture(Offset(bodyX, startY));
        for (var i = 1; i <= 5; i++) {
          final dy = rect.height * 0.05 * i * (down ? 1 : -1);
          await g.moveTo(Offset(bodyX, startY + dy));
          await sample('osc$o.move$i');
        }
        await g.up();
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 60));
        }
        await sample('osc$o.rest');
      }
      debugPrint('WASH1062_MIDSCROLL_WINDOW_CLOSED');

      expect(sawWashHiddenMidScroll, isTrue,
          reason: 'the wash was never hidden while scrolling — hide-on-scroll '
              'never engaged on-device (#1062)');
      expect(controller!.detectionScanStats.washHiddenForScroll, greaterThan(0),
          reason: 'the washHiddenForScroll telemetry must show the hide path '
              'fired during the scroll');

      // SETTLE: the wash re-shows on the correct tokens.
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      controller.reportPaintedViewportOffset(controller.scrollbar.offset);
      expect(controller.isScrolling, isFalse, reason: 'never settled');
      expect(renderBox().debugWashSuppressed, isFalse,
          reason: 'the wash must be un-suppressed once scrolling settles');
      expect(
        _driftedWashes(controller, controller.paintedViewportOffset),
        isEmpty,
        reason: 'after settle every wash must sit on its token (re-derived at '
            'the correct offset)',
      );
      debugPrint('WASH1062 pass: sawHiddenMidScroll=$sawWashHiddenMidScroll '
          'settledFramesChecked=$checkedSettledFrames driftWorst=$driftWorst '
          'washHiddenForScroll=${controller.detectionScanStats.washHiddenForScroll}');

      // SETTLED screenshot window: stationary, wash on its tokens.
      debugPrint('WASH1062_SETTLED_WINDOW_OPEN');
      for (var i = 0; i < 48; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      debugPrint('WASH1062_SETTLED_WINDOW_CLOSED');
    },
  );
}
