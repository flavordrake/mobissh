// On-emulator acceptance for #1064 (owner P0) — the detection WASH must be
// QUIESCE-GATED: visible ONLY when the screen is settled. It PAUSES (hides)
// while the screen is CHURNING — an active scroll OR content updating (a live
// TUI repainting in place) — and repaints at the fresh positions after a
// debounce once quiescent.
//
// This is the case +140 (#1062/#1063) MISSED: +140 paused the wash only on
// SCROLL (isScrolling). A live-updating TUI churns content WITHOUT scrolling
// (isScrolling=false, the grid rewritten in place), so +140 left the wash SHOWN
// at stale spots there. THIS test drives exactly that shape over SSH: a loop
// that repaints a fixed band of anchor lines IN PLACE (absolute cursor
// addressing, NO newline growth → the viewport never scrolls) so the churn is
// attributable to CONTENT, not scroll.
//
// Through the churn it asserts, against the REAL device paint stack:
//   * isScrolling is FALSE (the churn does not scroll), yet
//   * the render layer SUPPRESSES the wash (renderBox.debugWashSuppressed) — the
//     CONTENT-settle gate fires (contentSettling), and
//   * the washHiddenForContentChurn telemetry increments.
// Then, once the TUI stops, it asserts the wash RE-SHOWS on its tokens
// (not suppressed, on-glyph). It HOLDS for external screenshots at both phases:
//   DURING-CHURN (wash hidden) and SETTLED (wash on its tokens).
//
// Bridge: scripts/native-connect-test.sh (127.0.0.1:2222 → socat → test-sshd).
// Run: scripts/native-connect-test.sh integration_test/wash_quiesce_gate_1064_shot_test.dart

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

/// Every ON-SCREEN capsule wash cell-run that sits over cells NOT holding (part
/// of) its payload, mapped at [offset]. Empty == every visible wash is on its
/// token's glyphs.
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
    'the detection wash HIDES during an in-place content churn (isScrolling '
    'false) and re-shows on its tokens after settle (#1064 quiesce gate)',
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

      TerminalController? controllerOf() =>
          GhosttyTerminalView.debugControllers[sessionId];
      for (var i = 0; i < 40 && controllerOf() == null; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      final controller = controllerOf();
      expect(controller, isNotNull, reason: 'no ghostty controller for session');

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

      // A live-updating TUI that repaints a FIXED band of anchor lines IN PLACE
      // via ABSOLUTE cursor addressing (\033[<row>;1H) with \033[K erases and NO
      // trailing newline — so the viewport NEVER scrolls (isScrolling stays
      // false). 500 iterations × 0.05s ≈ 25s of continuous churn, long enough to
      // cover the sampling + during-churn screenshot windows below. When it stops
      // it clears and reprints the anchors settled, for the settled screenshot.
      const script = r'''
u=https://docs.brew.sh/Tap-Trust
p1=/Applications/Xcode.app/Contents/Developer
clear
i=0
while [ $i -lt 500 ]; do
  printf '\033[1;1H\033[Kbuild %d fetch %s' "$i" "$u"
  printf '\033[2;1H\033[Ksdk %s' "$p1"
  printf '\033[3;1H\033[Kstatus running task %d ...' "$i"
  i=$((i + 1))
  sleep 0.05
done
printf '\033[2J\033[H'
printf 'churn done CHURN1064DONE settled anchor washes:\n'
printf 'fetch %s\n' "$u"
printf 'sdk %s\n' "$p1"
printf 'prompt> \n'
''';
      entry.proxy.sendInput(Uint8List.fromList(utf8.encode('$script\n')));

      // ---- SAMPLE PHASE: through the churn, the wash must be HIDDEN by the
      // CONTENT gate (suppressed) while isScrolling stays FALSE.
      var sawHiddenDuringChurn = false;
      var sawScrollingDuringChurn = false;
      var sawWashData = false;
      var churnDone = false;
      for (var frame = 0; frame < 90 && !churnDone; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
        controller!.reportPaintedViewportOffset(controller.scrollbar.offset);
        final scrolling = controller.isScrolling;
        final suppressed = renderBox().debugWashSuppressed;
        final hasWash = controller.highlights.any((r) => r.capsule);
        if (scrolling) sawScrollingDuringChurn = true;
        if (hasWash) sawWashData = true;
        if (hasWash && suppressed && !scrolling) sawHiddenDuringChurn = true;
        if (utf8.decode(out, allowMalformed: true).contains('CHURN1064DONE')) {
          churnDone = true;
        }
      }

      expect(sawWashData, isTrue,
          reason: 'the TUI never surfaced a detected anchor — the ceiling '
              'rescan must bake a wash even mid-churn (precondition)');
      expect(sawScrollingDuringChurn, isFalse,
          reason: 'the in-place churn must NOT scroll — the hide must be '
              'attributable to the CONTENT gate, not scroll');
      expect(sawHiddenDuringChurn, isTrue,
          reason: 'the wash must HIDE during the content churn while '
              'isScrolling=false — the +140 gap this issue closes (#1064)');
      expect(controller!.detectionScanStats.washHiddenForContentChurn,
          greaterThan(0),
          reason: 'the washHiddenForContentChurn telemetry must show the '
              'content-pause path fired over live detected content');

      // ---- DURING-CHURN screenshot window: the churn is still running (well
      // inside the 25s remote loop); the wash is HIDDEN. Hold for emu-shot.
      debugPrint('WASH1064 churn sample OK: hidden=$sawHiddenDuringChurn '
          'scrolled=$sawScrollingDuringChurn '
          'washHiddenForContentChurn='
          '${controller.detectionScanStats.washHiddenForContentChurn}');
      if (!churnDone) {
        debugPrint('WASH1064_DURING_CHURN_WINDOW_OPEN');
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          controller.reportPaintedViewportOffset(controller.scrollbar.offset);
          expect(renderBox().debugWashSuppressed, isTrue,
              reason: 'the wash must stay hidden for the whole during-churn '
                  'screenshot window');
        }
        debugPrint('WASH1064_DURING_CHURN_WINDOW_CLOSED');
      }

      // ---- wait for the remote loop to finish (churn stops).
      for (var i = 0; i < 200 && !churnDone; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (utf8.decode(out, allowMalformed: true).contains('CHURN1064DONE')) {
          churnDone = true;
        }
      }
      expect(churnDone, isTrue, reason: 'the churn never stopped');

      // ---- SETTLE: after the churn stops + the debounce, the wash RE-SHOWS on
      // its tokens (the case that needs an explicit re-show: the churn ended on
      // the same URL token, so the equality-gated rescan would not notify).
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      controller.reportPaintedViewportOffset(controller.scrollbar.offset);
      expect(controller.isScrolling, isFalse, reason: 'not scrolling at settle');
      expect(controller.contentSettling, isFalse,
          reason: 'content must settle after the churn stops');
      expect(renderBox().debugWashSuppressed, isFalse,
          reason: 'the wash must be un-suppressed once content settles');
      expect(controller.highlights.any((r) => r.capsule), isTrue,
          reason: 'the wash must re-show after settle (not stranded hidden)');
      expect(
        _driftedWashes(controller, controller.paintedViewportOffset),
        isEmpty,
        reason: 'after settle every wash must sit on its token',
      );
      debugPrint('WASH1064 settle pass: contentSettling=${controller.contentSettling} '
          'suppressed=${renderBox().debugWashSuppressed}');

      // ---- SETTLED screenshot window: stationary, wash on its tokens.
      debugPrint('WASH1064_SETTLED_WINDOW_OPEN');
      for (var i = 0; i < 48; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      debugPrint('WASH1064_SETTLED_WINDOW_CLOSED');
    },
  );
}
